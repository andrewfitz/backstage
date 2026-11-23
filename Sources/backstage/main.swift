import Foundation
import AppKit
import ApplicationServices

let usage = """
backstage — drive macOS apps on an invisible display, without touching the user's screen,
cursor, keyboard focus or frontmost app. Output is JSON except for help, logs and plain-text trees.

COORDINATES: everything uses agent-display points with (0,0) at the display's top-left.
A default `screenshot` is cropped from (0,0), so image pixel (x,y) == click point (x,y)
(divide by --scale if you passed one). The display is Retina: a default screenshot is
downsampled to 1 pixel per point; --scale 2 gives the native pixels.

SESSIONS: each agent session sees and drives only the apps it launched. The session is
worked out automatically (the agent's own session ID, or its process); set BACKSTAGE_SESSION=name
to choose one, e.g. one per subagent. `status` shows the current session.

APP SELECTION: --pid P, or --app NAME (managed app name/bundle id), within your session.
Default: your session's most recently launched app.

LIFECYCLE
  launch <App.app|bundle.id|Name|/path/to/executable> [--env K=V]... [--timeout S] [-- args…]
  list [--all]                      your session's apps + their windows (--all: every session)
  quit [--pid P] [--force]          quit a managed app
  status | doctor                   daemon/display/permission status, and the display's
                                    `screencapture -D` index (to record it with standard tools)
  start                             start the daemon
  stop                              quit your session's apps (and the daemon, if no apps are left)
  stop --all                        quit every session's apps and stop the daemon
  logs [--pid P] [--lines N]        tail the app's stdout/stderr

HIDDEN OR SHOWN? Use launch for your own work (build checks, tests, debugging, screenshots).
Use show only when the user explicitly wants it on their screen.
  show --pid P                      hand a hidden app over to the user's screen (keeps its state)
  show <app|file|url>               open something on the user's screen

AGENT INTEGRATION
  install [--claude] [--codex] [--grok] [--hooks]   install the skill (and optionally the hook)
                                    into each agent; default = every agent found in ~
  uninstall [--claude] [--codex] [--grok]           remove skill + hook
  skill                             print the skill (SKILL.md)
  hook pre-tool-use                 hook entrypoint: blocks open/osascript-activate/.app binaries
                                    (bypass for a user-requested open: BACKSTAGE_SHOW=1 <cmd>)

SEE
  screenshot [-o out.png] [--window I] [--full] [--scale S]
                                    (--full: the whole display, showing all of your session's apps
                                    and nothing else)
  tree [--window I] [--depth N] [--json]           accessibility tree with element refs
  find [--role R] [--text T] [--window I]          find elements (text matches title/value/desc/id)
  windows                                           window list with frames
  window fill [--window I]                          make a window fill the display (below its menu bar)
  window size <w> <h> [--window I]                  resize a window (points); default window: frontmost
  wait --text T [--role R] [--gone] [--timeout S]   wait for an element to appear/disappear

ACT (all delivered in the background)
  press <ref>                       AXPress an element (buttons, checkboxes, menu items…)
  set <ref> <value>                 set an element's value (text fields, sliders…)
  focus <ref>                       focus an element (and make its window the app's key window)
  action <ref> <AXAction>           any AX action (e.g. AXIncrement, AXShowMenu, AXConfirm)
  click <x> <y> [--right] [--double]   mouse click at agent-display point
  click --ref <ref> [--right] [--double]
  hover <x> <y>                     best-effort: tracking-area hover effects/tooltips won't fire
  drag <x1> <y1> <x2> <y2>
  scroll <x> <y> [--dy N] [--dx N]  (pixels; negative dy scrolls down)
  type <text> [--ref R]             type into the focused element (or focus R first)
  key <combo>… [--ref R]            e.g. return, esc, tab, cmd+s, cmd+shift+z, down
  menu "File > Save As…"            press a menu bar item

Refs look like w8432.3.1 (window ID, then child indices). Re-run tree/find after the UI changes.
--window takes a window ref (w8432) or a front-to-back index (0 = frontmost).
"""

/// The app a command targets, within the calling session: `--pid`, `--app`, or the session's
/// most recent launch. Every app-targeting command goes through here, so this is the one
/// ownership check. Element refs resolve inside the selected app, so they're covered too.
func managedApp(_ args: Args) throws -> ManagedApp {
    let apps = try AppStore.read()
    let me = try Session.current().id
    let mine = apps.filter { $0.session == me }
    if let p = args.int("pid") {
        guard let a = apps.first(where: { $0.pid == p }) else { throw CLIError("pid \(p) is not a live managed app") }
        // Legacy records (from before sessions) have no owner, so an explicit PID still reaches them.
        guard a.session == me || a.session == nil else {
            throw CLIError("pid \(p) belongs to another backstage session; a session can only use apps it launched (see `backstage list`)")
        }
        return a
    }
    if let name = args.opt("app") {
        let n = name.lowercased()
        guard let a = mine.last(where: { $0.name.lowercased() == n || $0.bundleID?.lowercased() == n })
                ?? mine.last(where: { $0.name.lowercased().contains(n) }) else {
            throw CLIError("no managed app matching '\(name)' in this session. Yours: \(mine.map { "\($0.name)(\($0.pid))" }.joined(separator: ", "))")
        }
        return a
    }
    guard let last = mine.max(by: { $0.launchedAt < $1.launchedAt }) else {
        throw CLIError("no managed apps in this session; run `backstage launch <app>` first")
    }
    return last
}

func managedPid(_ args: Args) throws -> pid_t { try managedApp(args).pid }

func requireDaemon() throws -> DaemonInfo {
    if let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess, d.protocolMismatch { throw daemonVersionError(d) }
    guard let d = liveDaemon() else { throw CLIError("daemon not running (run `backstage launch …` or `backstage start`)") }
    return d
}

/// Input that can open a menu (a right-click, a pressed pop-up button or menu bar item) hands
/// the app the keyboard focus; only the daemon's input guard keeps the user's typing out of it.
/// Without the guard, refuse rather than risk it.
func requireInputGuard() throws {
    guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else {
        throw CLIError("the backstage daemon isn't running, and without its input guard the user's typing could reach this app "
            + "while one of its menus is open; `backstage stop --all`, then launch the app again")
    }
    guard let up = d.inputGuard else {
        throw CLIError("the running backstage daemon (pid \(d.pid)) is from an older build without the input guard; "
            + "run `backstage stop --all` (quits every managed app) to replace it, then retry")
    }
    guard up else {
        throw CLIError("the backstage daemon's input guard isn't running (see \(Paths.log.path)), so the user's typing could reach "
            + "this app while one of its menus is open. Check Accessibility for the app running backstage, then `backstage stop --all` and retry")
    }
}

func elementCenter(_ e: AXUIElement) throws -> CGPoint {
    guard let f = e.frame else { throw CLIError("element has no frame") }
    return CGPoint(x: f.midX, y: f.midY)
}

/// Make the element's window the app's key window (within the app only — the app is never
/// really activated, so the user's focus is untouched) so keystrokes land there.
func focusWindowOf(_ e: AXUIElement, pid: pid_t) {
    var w = e
    if w.role != "AXWindow", let win = e.attr(kAXWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() { w = win as! AXUIElement }
    guard w.role == "AXWindow" else { return }
    primeActivation(pid)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    usleep(50_000)
}

func focusRef(_ ref: String?, pid: pid_t) throws {
    guard let ref else { return }
    let e = try resolveRef(pid, ref)
    focusWindowOf(e, pid: pid)
    let status = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard status == .success else { throw CLIError("could not focus \(ref) (AXError \(status.rawValue))") }
    pump(0.05)
}

func elementAt(_ p: CGPoint, pid: pid_t) -> AXUIElement? {
    var e: AXUIElement?
    guard AXUIElementCopyElementAtPosition(axApp(pid), Float(p.x), Float(p.y), &e) == .success, let e, e.pid == pid else { return nil }
    return e
}

/// Real (background) mouse click at a global point.
func doClick(global p: CGPoint, pid: pid_t, args: Args) throws -> [String: Any] {
    guard let hit = hitTest(p, pids: [pid]) else { throw CLIError("no window of pid \(pid) at that point (take a screenshot / check `windows`)") }
    // A click on a non-key window is consumed as "focus this window" (same as for a human), so
    // make the target window key inside the app first. Menus/popovers aren't AX windows: skip those.
    if let w = axApp(pid).windows.first(where: { $0.windowID == hit.windowID }), (w.attr(kAXMainAttribute) as? Bool) != true {
        focusWindowOf(w, pid: pid)
    }
    postClick(at: p, hit: hit, right: args.has("right"), count: args.has("double") ? 2 : 1)
    var res: [String: Any] = ["ok": true, "windowID": hit.windowID, "via": "mouse"]
    if let e = elementAt(p, pid: pid), let i = try? info(e, ref: "", depth: 0) {
        res["element"] = i.label.isEmpty ? i.role : "\(i.role) \(i.label.prefix(60))"
    }
    return res
}

func cmdScreenshot(_ args: Args) throws -> [String: Any] {
    let d = try requireDaemon()
    let vd = d.bounds
    let scale = args.double("scale") ?? 1
    let me = try Session.current().id
    let outArg: String
    if let given = args.opt("o") ?? args.opt("out") {
        outArg = given
    } else {
        let folder = Paths.shots.appendingPathComponent(Session.fileKey(me))
        try Paths.ensureDirectory(folder)
        outArg = folder.appendingPathComponent("shot-\(UUID().uuidString).png").path
    }
    let out = URL(fileURLWithPath: (outArg as NSString).expandingTildeInPath)
    if args.has("full") {
        // The display is shared: capture every window of this session's apps (and nothing
        // else, from the same window snapshot), over the whole display.
        let pids = Set(try AppStore.read().filter { $0.session == me }.map { $0.pid })
        guard !pids.isEmpty else { throw CLIError("no managed apps in this session; --full captures all of your session's apps, so launch one first") }
        let size = try capture(.apps(pids, display: d.displayID, crop: vd), to: out, scale: scale)
        return ["path": out.path, "width": Int(size.width), "height": Int(size.height), "origin": ["x": 0, "y": 0], "scale": scale,
                "pids": pids.sorted()]
    }
    let pid = try managedPid(args)
    if let ws = args.opt("window") {
        let w = try resolveWindow(pid, ws)
        guard let wid = w.windowID, let f = w.frame else { throw CLIError("window \(ws) has no id/frame") }
        let size = try capture(.window(wid), to: out, scale: scale)
        return ["path": out.path, "width": Int(size.width), "height": Int(size.height),
                "origin": ["x": r(f.minX - vd.minX), "y": r(f.minY - vd.minY)], "scale": scale,
                "note": "pixel (px,py) -> point (origin.x + px/scale, origin.y + py/scale)"]
    }
    // Union of the app's on-screen windows (incl. menus, sheets, popovers), cropped from the display's origin.
    var union = CGRect.null
    for w in onscreenWindows() where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let b = cgBounds(w)
        if vd.intersects(b) { union = union.union(b.intersection(vd)) }
    }
    guard !union.isNull else { throw CLIError("app \(pid) has no visible windows on the agent display") }
    let crop = CGRect(x: vd.minX, y: vd.minY, width: union.maxX - vd.minX, height: union.maxY - vd.minY)
    let size = try capture(.apps([pid], display: d.displayID, crop: crop), to: out, scale: scale)
    return ["path": out.path, "width": Int(size.width), "height": Int(size.height), "origin": ["x": 0, "y": 0], "scale": scale, "pid": pid]
}

/// The agent display's usable area, in global points: the display below its menu bar.
func agentVisibleFrame(_ d: DaemonInfo) -> CGRect {
    let bounds = d.bounds
    guard let screen = nsScreen(d.displayID) else { return bounds }
    // NSScreen is bottom-left based, from the bottom of the primary display.
    let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
    let v = screen.visibleFrame
    let area = CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height).intersection(bounds)
    return area.isEmpty ? bounds : area
}

/// `window fill` / `window size <w> <h>`: resize one of the app's windows (default: its frontmost)
/// with AX, staying inside the agent display.
func cmdWindow(_ args: Args, pid: pid_t) throws -> [String: Any] {
    let d = try requireDaemon()
    let spec = args.opt("window") ?? "0"
    let w = try resolveWindow(pid, spec)
    guard let current = w.frame else { throw CLIError("window \(spec) has no frame") }
    let area = agentVisibleFrame(d)
    let target: CGRect
    switch (args.pos(0), args.positional.count) {
    case ("fill", 1):
        target = area
    case ("size", 3):
        // Args has checked both are finite numbers >= 1.
        let width = Double(args.pos(1)!)!, height = Double(args.pos(2)!)!
        guard width <= area.width, height <= area.height else {
            throw CLIError("\(r(width))x\(r(height)) doesn't fit the agent display's usable area (\(r(area.width))x\(r(area.height)) points); start the daemon with a larger BACKSTAGE_WIDTH/BACKSTAGE_HEIGHT")
        }
        // Keep the window where it is, moving it only as far as needed to stay on the display.
        target = CGRect(x: min(max(current.minX, area.minX), area.maxX - width),
                        y: min(max(current.minY, area.minY), area.maxY - height), width: width, height: height)
    default:
        throw CLIError("usage: backstage window fill [--window W]  |  backstage window size <w> <h> [--window W]")
    }
    // Move, resize, move again: the system may constrain a resize by where the window is.
    w.setPosition(target.origin)
    let rc = w.setSize(target.size)
    w.setPosition(target.origin)
    guard rc == .success else { throw CLIError("could not resize window \(spec) (AXError \(rc.rawValue)); it may not be resizable") }
    pump(0.1)
    let got = w.frame ?? target
    var res: [String: Any] = ["ok": true, "pid": pid, "window": windowRef(w, index: Int(spec) ?? 0),
                              "frame": rectDict(got.offsetBy(dx: -d.bounds.minX, dy: -d.bounds.minY))]
    if abs(got.width - target.width) > 1 || abs(got.height - target.height) > 1 {
        res["requested"] = rectDict(target.offsetBy(dx: -d.bounds.minX, dy: -d.bounds.minY))
        res["note"] = "the app limited the window's size (minimum/maximum size or a fixed-size window)"
    }
    return res
}

func cmdTree(_ args: Args) throws {
    let d = try requireDaemon()
    let pid = try managedPid(args)
    let depth = args.int("depth") ?? 40
    if args.has("json") {
        var nodes: [[String: Any]] = []
        try walkTree(pid: pid, window: args.opt("window"), maxDepth: depth) { i, _ in nodes.append(i.json(origin: d.bounds.origin)); return true }
        emit(["pid": pid, "elements": nodes])
    } else {
        var n = 0
        try walkTree(pid: pid, window: args.opt("window"), maxDepth: depth) { i, _ in
            // Skip anonymous leaf-ish groups to keep output compact.
            print(i.line(origin: d.bounds.origin)); n += 1; return true
        }
        if n == 0 { print("(no windows — is the app still loading? try `backstage windows`)") }
    }
}

func matches(_ i: ElementInfo, role: String?, text: String?) -> Bool {
    if let role, !i.role.lowercased().contains(role.lowercased()) && i.subrole?.lowercased().contains(role.lowercased()) != true { return false }
    if let text, !i.label.lowercased().contains(text.lowercased()) { return false }
    return true
}

func cmdFind(_ args: Args) throws -> [String: Any] {
    let d = try requireDaemon()
    let pid = try managedPid(args)
    let role = args.opt("role"), text = args.opt("text") ?? args.pos(0)
    var out: [[String: Any]] = []
    try walkTree(pid: pid, window: args.opt("window"), maxDepth: 60) { i, _ in
        if matches(i, role: role, text: text) { out.append(i.json(origin: d.bounds.origin)) }
        return out.count < 200
    }
    return ["pid": pid, "count": out.count, "elements": out]
}

func cmdWait(_ args: Args) throws -> [String: Any] {
    let d = try requireDaemon()
    let pid = try managedPid(args)
    let role = args.opt("role"), text = args.opt("text") ?? args.pos(0)
    guard role != nil || text != nil else { throw CLIError("wait needs --text and/or --role") }
    let gone = args.has("gone")
    let t0 = Date()
    let found: [String: Any]? = try waitFor(timeout: args.double("timeout") ?? 10, interval: 0.2) {
        var hit: ElementInfo?
        try walkTree(pid: pid, window: args.opt("window"), maxDepth: 60) { i, _ in
            if matches(i, role: role, text: text) { hit = i; return false }
            return true
        }
        if gone { return hit == nil ? ["gone": true] : nil }
        return hit.map { $0.json(origin: d.bounds.origin) }
    }
    guard let found else { throw CLIError("timed out after \(args.double("timeout") ?? 10)s waiting for \(gone ? "disappearance of " : "")\(text ?? "") \(role ?? "")") }
    return ["ok": true, "element": found, "seconds": (Date().timeIntervalSince(t0) * 100).rounded() / 100]
}

func cmdList(_ args: Args) throws -> [String: Any] {
    let origin = liveDaemon()?.bounds.origin ?? .zero
    let me = try Session.current().id
    let apps = try AppStore.read().filter { args.has("all") || $0.session == me }.map { a -> [String: Any] in
        var d: [String: Any] = ["pid": a.pid, "name": a.name, "path": a.path, "session": a.owner,
                                "windows": axWindowsSummary(a.pid, origin: origin)]
        if let b = a.bundleID { d["bundleID"] = b }
        if let s = a.stdout { d["log"] = s }
        return d
    }
    return ["session": me, "apps": apps]
}

func cmdStatus() throws -> [String: Any] {
    let accessibility = AXIsProcessTrusted()
    let recording = CGPreflightScreenCaptureAccess()
    var s: [String: Any] = [
        "accessibility": accessibility,
        "screenRecording": recording,
        "home": Paths.dir.path,
    ]
    if let d = liveDaemon() {
        var daemon: [String: Any] = ["pid": d.pid, "displayID": d.displayID, "size": ["w": Int(d.width), "h": Int(d.height)],
                                     "globalOrigin": ["x": Int(d.x), "y": Int(d.y)]]
        if let source = d.sizeSource { daemon["sizeSource"] = source }
        daemon["inputGuard"] = d.inputGuard == true
        if let mode = CGDisplayCopyDisplayMode(d.displayID) {
            daemon["pixels"] = ["w": mode.pixelWidth, "h": mode.pixelHeight]
            daemon["scale"] = d.width > 0 ? Double(mode.pixelWidth) / d.width : 1
        }
        // For recording with standard tools: `screencapture -D` counts the active displays from
        // 1, ffmpeg's avfoundation names them "Capture screen 0", 1… in the same order. The order
        // changes when displays come and go, so read it just before recording.
        if let i = activeDisplays().firstIndex(of: d.displayID) {
            daemon["screencaptureDisplay"] = i + 1
            daemon["ffmpegScreen"] = "Capture screen \(i)"
        }
        s["daemon"] = daemon
    } else {
        s["daemon"] = NSNull()
    }
    do {
        let session = try Session.current()
        s["session"] = ["id": session.id, "from": session.source]
    } catch {
        s["session"] = ["error": "\(error)"]
    }
    s["managedApps"] = try AppStore.read().map { ["pid": $0.pid, "name": $0.name, "session": $0.owner] }
    var problems: [String] = []
    if !accessibility { problems.append("Accessibility not granted: System Settings > Privacy & Security > Accessibility — enable the app that runs this CLI (your terminal / agent host).") }
    if let d = liveDaemon(), d.inputGuard != true {
        problems.append("The daemon's input guard isn't running (see \(Paths.log.path)), so input commands refuse to run. Check Accessibility, then `backstage stop --all`.")
    }
    if !recording { problems.append("Screen Recording not granted: System Settings > Privacy & Security > Screen & System Audio Recording — enable the terminal / agent host, then restart it.") }
    s["ok"] = problems.isEmpty
    if !problems.isEmpty { s["problems"] = problems }
    return s
}

func cmdQuit(_ args: Args) throws -> [String: Any] {
    let target = try managedApp(args)
    let pid = target.pid
    let lock = try Locks.session(target.owner)
    defer { lock.release() }
    guard let record = try AppStore.read().first(where: { $0.pid == pid && $0.processStart == target.processStart }) else {
        return ["ok": true, "note": "already gone"]
    }
    let force = args.has("force")
    try record.requestTermination(force: force)
    let gone = waitFor(timeout: force ? 7 : 5) { record.matchesProcess ? nil : true } != nil
    if !gone && !force {
        return ["ok": false, "pid": pid, "note": "app didn't quit (unsaved-changes dialog?). Inspect with screenshot/tree, or use --force"]
    }
    if gone {
        // Prune by process identity so a concurrent registration survives PID reuse.
        try AppStore.update { _ in }
        Locks.pruneAppLocks()
    }
    return ["ok": gone, "pid": pid]
}

func cmdLogs(_ args: Args) throws {
    let pid = try managedPid(args)
    guard let a = try AppStore.read().first(where: { $0.pid == pid }), let path = a.stdout else { throw CLIError("no log for pid \(pid)") }
    let n = args.int("lines") ?? 100
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    guard n > 0 else { return }
    let end = try file.seekToEnd()
    // Locate the first requested line in reverse blocks, then stream that byte range.
    var start = end
    var remaining = n
    let block = 64 * 1024
    while start > 0 && remaining > 0 {
        let offset = start - min(start, UInt64(block))
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: Int(start - offset)) ?? Data()
        start = offset
        for index in data.indices.reversed() where data[index] == 10 {
            let after = offset + UInt64(index + 1)
            if after == end { continue }
            remaining -= 1
            if remaining == 0 { start = after; break }
        }
    }
    try file.seek(toOffset: start)
    var bytesLeft = end - start
    while bytesLeft > 0 {
        guard let data = try file.read(upToCount: Int(min(bytesLeft, UInt64(block)))), !data.isEmpty else { break }
        try FileHandle.standardOutput.write(contentsOf: data)
        bytesLeft -= UInt64(data.count)
    }
}

func point(_ args: Args, _ i: Int, _ vd: CGRect) throws -> CGPoint {
    guard let xs = args.pos(i), let ys = args.pos(i + 1), let x = Double(xs), let y = Double(ys) else { throw CLIError("expected x y coordinates") }
    let s = args.double("scale") ?? 1
    let point = CGPoint(x: vd.minX + x / s, y: vd.minY + y / s)
    guard x.isFinite, y.isFinite, vd.contains(point) else { throw CLIError("coordinates must be inside the agent display") }
    return point
}

func run() throws {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let cmd = argv.first else { print(usage); return }
    argv.removeFirst()
    let args = try Args(argv, command: cmd)
    if args.has("help") { print(usage); return }

    // Input commands hold the target app's lock from focus through the last event, so two
    // clients typing into one app can't interleave. Other apps are unaffected.
    var input: (pid: pid_t, lock: StateLock)?
    if ["press", "focus", "action", "set", "click", "hover", "drag", "scroll", "type", "key", "menu", "window"].contains(cmd) {
        let app = try managedApp(args)
        if cmd != "window" { try requireInputGuard() }
        input = (app.pid, try Locks.app(app))
    }
    defer { input?.lock.release() }
    func inputTarget() throws -> pid_t { try input?.pid ?? managedPid(args) }

    switch cmd {
    case "__guard-selftest":
        let result = guardSelfTest()
        emit(result)
        if result["ok"] as? Bool != true { exit(1) }
    case "__daemon":
        try Paths.ensure()
        let d = try Daemon()
        Daemon.shared = d
        try d.run()
    case "help", "-h", "--help": print(usage)
    case "start": let d = try ensureDaemon(); emit(["ok": true, "pid": d.pid, "displayID": d.displayID])
    case "stop":
        let result = try args.has("all") ? stopAll() : stopSession()
        emit(result)
        if result["ok"] as? Bool == false { exit(1) }
    case "status", "doctor": emit(try cmdStatus())
    case "launch", "open": emit(try launch(args))
    case "list", "ps": emit(try cmdList(args))
    case "show": emit(try cmdShow(args))
    case "install": emit(try cmdInstall(args))
    case "uninstall": emit(try cmdUninstall(args))
    case "skill": print(skillMarkdown, terminator: skillMarkdown.hasSuffix("\n") ? "" : "\n")
    case "hook":
        guard args.pos(0) == "pre-tool-use" else { throw CLIError("usage: backstage hook pre-tool-use  (reads the agent's hook JSON on stdin)") }
        runPreToolUseHook()
    case "quit", "kill":
        let result = try cmdQuit(args)
        emit(result)
        if result["ok"] as? Bool == false { exit(1) }
    case "logs": try cmdLogs(args)
    case "window": emit(try cmdWindow(args, pid: try inputTarget()))
    case "windows":
        let d = try requireDaemon(); let pid = try managedPid(args)
        emit(["pid": pid, "windows": axWindowsSummary(pid, origin: d.bounds.origin)])
    case "screenshot", "shot": emit(try cmdScreenshot(args))
    case "tree": try cmdTree(args)
    case "find": emit(try cmdFind(args))
    case "wait": emit(try cmdWait(args))
    case "press", "focus", "action", "set":
        let pid = try inputTarget()
        guard let ref = args.pos(0) else { throw CLIError("usage: backstage \(cmd) <ref>") }
        let e = try resolveRef(pid, ref)
        let rc: AXError
        switch cmd {
        case "press": rc = AXUIElementPerformAction(e, kAXPressAction as CFString)
        case "focus":
            focusWindowOf(e, pid: pid)
            rc = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "action":
            guard let a = args.pos(1) else { throw CLIError("usage: backstage action <ref> <AXAction>") }
            rc = AXUIElementPerformAction(e, (a.hasPrefix("AX") ? a : "AX" + a) as CFString)
        default:
            guard let v = args.pos(1) else { throw CLIError("usage: backstage set <ref> <value>") }
            let cur = e.attr(kAXValueAttribute)
            let val: CFTypeRef = (cur is NSNumber) ? (Double(v).map { NSNumber(value: $0) } ?? v as NSString) : v as NSString
            rc = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, val)
        }
        guard rc == .success else { throw CLIError("\(cmd) failed: AXError \(rc.rawValue)\(rc == .actionUnsupported ? " (unsupported — try `click --ref \(ref)`)" : "")") }
        pump(0.15)
        emit(["ok": true])
    case "click":
        let d = try requireDaemon(); let pid = try inputTarget()
        var res: [String: Any]
        var location: CGPoint?
        if let ref = args.opt("ref") {
            // Element click: AXPress when the element supports it (most reliable), else mouse at its center.
            let e = try resolveRef(pid, ref)
            location = try? elementCenter(e)
            if !args.has("right") && !args.has("double") && !args.has("raw") && e.actions.contains(kAXPressAction as String),
               AXUIElementPerformAction(e, kAXPressAction as CFString) == .success {
                res = ["ok": true, "via": "ax-press"]
            } else {
                guard let location, d.bounds.contains(location) else { throw CLIError("element has no clickable center on the agent display") }
                res = try doClick(global: location, pid: pid, args: args)
            }
        } else {
            let p = try point(args, 0, d.bounds)
            location = p
            res = try doClick(global: p, pid: pid, args: args)
        }
        if let location { res["at"] = ["x": r(location.x - d.bounds.minX), "y": r(location.y - d.bounds.minY)] }
        pump(0.15)
        emit(res)
    case "hover":
        let d = try requireDaemon(); let pid = try inputTarget()
        let p = try point(args, 0, d.bounds)
        guard let hit = hitTest(p, pids: [pid]) else { throw CLIError("no window of pid \(pid) at that point") }
        if let w = axApp(pid).windows.first(where: { $0.windowID == hit.windowID }), (w.attr(kAXMainAttribute) as? Bool) != true {
            focusWindowOf(w, pid: pid)
        }
        primeActivation(pid)
        // A short approach path so enter/move handlers see motion, not a single teleport.
        for i in stride(from: 4, through: 0, by: -1) {
            postMove(to: CGPoint(x: p.x - CGFloat(i * 3), y: p.y), hit: hit); usleep(15_000)
        }
        pump(0.1); emit(["ok": true])
    case "drag":
        let d = try requireDaemon(); let pid = try inputTarget()
        let a = try point(args, 0, d.bounds), b = try point(args, 2, d.bounds)
        guard let hit = hitTest(a, pids: [pid]) else { throw CLIError("no window of pid \(pid) at start point") }
        postDrag(from: a, to: b, hit: hit, steps: args.int("steps") ?? 20); pump(0.15); emit(["ok": true])
    case "scroll":
        let d = try requireDaemon(); let pid = try inputTarget()
        let p = try point(args, 0, d.bounds)
        guard let hit = hitTest(p, pids: [pid]) else { throw CLIError("no window of pid \(pid) at that point") }
        postScroll(at: p, hit: hit, dx: Int32(args.int("dx") ?? 0), dy: Int32(args.int("dy") ?? -100)); pump(0.15); emit(["ok": true])
    case "type":
        let pid = try inputTarget()
        guard let text = args.pos(0) else { throw CLIError("usage: backstage type <text> [--ref R]") }
        try focusRef(args.opt("ref"), pid: pid)
        postText(pid: pid, text: text); pump(0.1); emit(["ok": true, "chars": text.count])
    case "key":
        let pid = try inputTarget()
        let keys = try args.positional.map(parseCombo)
        try focusRef(args.opt("ref"), pid: pid)
        for key in keys { postKey(pid: pid, key: key) }
        pump(0.1); emit(["ok": true])
    case "menu":
        let pid = try inputTarget()
        guard let path = args.pos(0) else { throw CLIError("usage: backstage menu \"File > Save\"") }
        try pressMenu(pid: pid, path: path); pump(0.2); emit(["ok": true])
    default:
        throw CLIError("unknown command '\(cmd)'. Run `backstage help`.")
    }
}

do {
    try run()
} catch {
    emit(["ok": false, "error": "\(error)"])
    exit(1)
}
