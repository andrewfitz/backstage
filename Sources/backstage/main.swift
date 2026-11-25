import Foundation
import AppKit
import ApplicationServices

let usage = """
backstage — drive macOS apps on an invisible display, without touching the user's screen,
cursor, keyboard focus or frontmost app. Output is JSON except for help, version, skill, logs and plain-text trees.

COORDINATES: everything uses agent-display points with (0,0) at the display's top-left.
A default `screenshot` is cropped from (0,0), so image pixel (x,y) == click point (x,y)
(divide by --scale if you passed one). The display is Retina: a default screenshot is
downsampled to 1 pixel per point; --scale 2 gives the native pixels.

SESSIONS: each agent session sees and drives only the apps it launched. The session is
worked out automatically (the agent's own session ID, or its process); set BACKSTAGE_SESSION=name
to choose one, e.g. one per subagent. `status` shows the current session.

APP SELECTION: --pid P, or --app NAME (managed app name/bundle id), within your session.
Default: your session's most recently launched app. Apps the user sent backstage themselves
(session "user", see `list --all`) are reachable with an explicit --pid/--app, never by default.

LIFECYCLE
  launch <App.app|bundle.id|Name|/path/to/executable> [--env K=V]... [--timeout S] [--dock]
         [--audio | --inaudible] [--display N|new] [-- args…]
                                    hidden, muted, no Dock tile or ⌘-Tab entry (--dock: with one).
                                    Dev builds and test runners are also made inaudible everywhere,
                                    screen sharing and recordings included ("audio": "inaudible");
                                    other apps are muted on this Mac only ("audio": "muted").
                                    --audio: measure its sound (screen sharing can hear it);
                                    --inaudible: fail unless it can be made inaudible
                                    --display new: a display of your own (reserved for your session
                                    for 30 min; removed 30 min after its last app); --display N: that
                                    one. Without it: your session's display, else display 1. A result
                                    with "crowded": true means the window found no free spot
  list [--all]                      your session's apps + their windows (--all: every session)
  quit [--pid P] [--force]          quit a managed app
  move --display N|new [--pid P]    move an app to another display (coordinates follow it)
  status | doctor                   daemon/display/permission status, and the display's
                                    `screencapture -D` index (to record it with standard tools;
                                    with several displays, each one's under daemon.displays);
                                    doctor also runs the audio self-test (inaudible, muted probe)
  start                             start the daemon
  stop                              quit your session's apps (and the daemon, if no apps are left)
  stop --all                        quit every session's apps (and apps the user sent backstage)
                                    and stop the daemon
  settings                          show settings (also in `status`)
  settings keep-in-menu-bar on|off  keep the menu bar icon (and the daemon) up with no apps running
  settings hotkey <combo|off|default>   Send Front Window Backstage shortcut (off by default);
                                    default chooses ctrl+opt+cmd+b. A custom shortcut needs two or
                                    more modifiers incl. cmd or ctrl, plus a letter, digit or F-key
  logs [--pid P] [--lines N]        tail the app's stdout/stderr
  cleanup-displays                  (sudo) remove leftover backstage displays from ColorSync
  version                           print the version (also `status`'s "version")

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
  screenshot [-o out.png] [--window I] [--full [--display N]] [--scale S]
                                    (--full: the whole display, showing all of your session's apps
                                    and nothing else)
  tree [--window I] [--depth N] [--json]           accessibility tree with element refs
  find [--role R] [--text T] [--window I]          find elements (text matches title/value/desc/id)
  windows                                           window list with frames
  window fill [--window I]                          make a window fill the display (below its menu bar)
  window size <w> <h> [--window I]                  resize a window (points); default window: frontmost
  wait --text T [--role R] [--gone] [--timeout S]   wait for an element to appear/disappear

HEAR (apps are always muted: nothing they play reaches the speakers; `show` unmutes)
  Only apps launched with --audio are measured; these commands refuse any other app.
  audio                             the app's audio: tap state, playing, levels (dBFS), dominant
                                    frequency, recent sounds, and `time` (the clock for --since)
  wait --sound [--gone] [--since T] [--min-db D] [--timeout S]
                                    wait until the app plays sound (or, with --gone, stops);
                                    --since T also counts a sound that started at/after T and is
                                    already over
  audio record [-o out.wav] [--seconds N]
                                    WAV (float32, as tapped) of the last N s (default and max 15)
                                    the app's output ran; without -o, into the screenshots folder
  These need System Audio Recording for the daemon's host (see doctor); muting doesn't.

ACT (all delivered in the background)
  press <ref>                       AXPress an element (buttons, checkboxes, menu items…)
  set <ref> <value>                 set an element's value (text fields, sliders…)
  focus <ref>                       focus an element (and make its window the app's key window)
  action <ref> <AXAction>           any AX action (e.g. AXIncrement, AXShowMenu, AXConfirm)
  click <x> <y> [--right] [--double]   mouse click at agent-display point
  click --ref <ref> [--right] [--double]
  hover <x> <y>                     best-effort: tracking-area hover effects/tooltips won't fire
  drag <x1> <y1> <x2> <y2> [--steps N]   interpolate over 1-1000 steps (default 20)
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
    let me = try Session.current().id
    if let p = args.int("pid") {
        guard let a = try AppStore.read(matching: { $0.pid == p }).first else { throw CLIError("pid \(p) is not a live managed app") }
        // Legacy records (from before sessions) have no owner, and apps the user sent backstage
        // were handed to agents on purpose: an explicit PID reaches both.
        guard a.session == nil || Session.sameID(a.session, me) || Session.isUser(a.session) else {
            throw CLIError("pid \(p) belongs to another backstage session; a session can only use apps it launched (see `backstage list`)")
        }
        return a
    }
    if let name = args.opt("app") {
        let visible = try AppStore.read(matching: { Session.sameID($0.session, me) || Session.isUser($0.session) })
        let mine = visible.filter { Session.sameID($0.session, me) }
        let n = name.lowercased()
        func pick(_ apps: [ManagedApp]) -> ManagedApp? {
            apps.reversed().lazy.filter({ $0.name.lowercased() == n || $0.bundleID?.lowercased() == n })
                .max(by: { $0.launchedAt < $1.launchedAt })
                ?? apps.reversed().lazy.filter({ $0.name.lowercased().contains(n) }).max(by: { $0.launchedAt < $1.launchedAt })
        }
        // Your own apps first, then apps the user sent backstage (never another session's).
        guard let a = pick(mine) ?? pick(visible.filter { Session.isUser($0.session) }) else {
            throw CLIError("no managed app matching '\(name)' in this session or sent backstage by the user. Yours: \(mine.map { "\($0.name)(\($0.pid))" }.joined(separator: ", "))")
        }
        return a
    }
    let mine = try AppStore.read(matching: { Session.sameID($0.session, me) })
    guard let last = mine.max(by: { $0.launchedAt < $1.launchedAt }) else {
        throw CLIError("no managed apps in this session; run `backstage launch <app>` first")
    }
    return last
}

func rejectIncompatibleDaemon() throws {
    if let d = readJSON(Paths.daemon, DaemonInfo.self), d.protocolMismatch, d.matchesProcess {
        throw daemonVersionError(d)
    }
}

func requireDaemon() throws -> DaemonInfo {
    guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else {
        throw CLIError("daemon not running (run `backstage launch …` or `backstage start`)")
    }
    if d.protocolMismatch { throw daemonVersionError(d) }
    guard d.stopping != true else { throw CLIError("the backstage daemon is shutting down; try again") }
    guard let running = liveDisplay(d) else { throw CLIError("the backstage daemon's display isn't available") }
    return running
}

/// The daemon as seen from a managed app's display: bounds and display ID are that display's,
/// so coordinates, crops and placement are relative to it (docs/MULTI_DISPLAY_PLAN.md).
func daemonView(_ d: DaemonInfo, for app: ManagedApp) throws -> DaemonInfo {
    let slot = app.display
    guard let view = d.on(slot) else {
        throw CLIError("display \(slot.map(String.init) ?? "?") of pid \(app.pid) is gone; move it with `backstage move --pid \(app.pid) --display \(d.primarySlot)`")
    }
    return view
}

/// Input that can open a menu (a right-click, a pressed pop-up button or menu bar item) hands
/// the app the keyboard focus; only the daemon's input guard keeps the user's typing out of it.
/// Without the guard, refuse rather than risk it.
func requireInputGuard() throws {
    guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else {
        throw CLIError("the backstage daemon isn't running, and without its input guard the user's typing could reach this app "
            + "while one of its menus is open; `backstage stop --all`, then launch the app again")
    }
    if d.protocolMismatch { throw daemonVersionError(d) }
    guard d.stopping != true else { throw CLIError("the backstage daemon is shutting down; try again") }
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
func focusWindowOf(_ e: AXUIElement, pid: pid_t, birth: UInt64) {
    var w = e
    if w.role != "AXWindow", let win = e.attr(kAXWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() { w = win as! AXUIElement }
    guard w.role == "AXWindow", w.pid == pid, processBirth(pid) == birth else { return }
    primeActivation(pid, birth: birth)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    usleep(50_000)
}

func focusRef(_ ref: String?, pid: pid_t, birth: UInt64) throws {
    guard let ref else { return }
    let e = try resolveRef(pid, ref)
    focusWindowOf(e, pid: pid, birth: birth)
    guard processBirth(pid) == birth else { throw CLIError("pid \(pid) exited before it could receive input") }
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
func doClick(global p: CGPoint, pid: pid_t, birth: UInt64, args: Args) throws -> [String: Any] {
    guard let hit = hitTest(p, pids: [pid]) else { throw CLIError("no window of pid \(pid) at that point (take a screenshot / check `windows`)") }
    // A click on a non-key window is consumed as "focus this window" (same as for a human), so
    // make the target window key inside the app first. Menus/popovers aren't AX windows: skip those.
    if let w = axApp(pid).windows.first(where: { $0.windowID == hit.windowID }), (w.attr(kAXMainAttribute) as? Bool) != true {
        focusWindowOf(w, pid: pid, birth: birth)
    }
    try postClick(at: p, hit: hit, right: args.has("right"), count: args.has("double") ? 2 : 1, birth: birth)
    var res: [String: Any] = ["ok": true, "windowID": hit.windowID, "via": "mouse"]
    if let e = elementAt(p, pid: pid), let i = try? info(e, ref: "", depth: 0) {
        res["element"] = i.label.isEmpty ? i.role : "\(i.role) \(i.label.prefix(60))"
    }
    return res
}

func cmdScreenshot(_ args: Args) throws -> [String: Any] {
    let base = try requireDaemon()
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
        let mine = try AppStore.read(matching: { Session.sameID($0.session, me) })
        guard !mine.isEmpty else { throw CLIError("no managed apps in this session; --full captures all of your session's apps, so launch one first") }
        // One display at a time: --display N, or the one display this session's apps are on.
        let slots = Set(mine.map { $0.display ?? base.primarySlot })
        let slot: Int
        if let raw = args.opt("display") {
            guard let n = Int(raw) else { throw CLIError("--display takes a display number") }
            slot = n
        } else {
            guard slots.count == 1, let only = slots.first else {
                throw CLIError("your session's apps are on displays \(slots.sorted().map(String.init).joined(separator: ", ")); pick one with --display N")
            }
            slot = only
        }
        guard let d = base.on(slot) else { throw CLIError("display \(slot) isn't running") }
        let apps = mine.filter { ($0.display ?? base.primarySlot) == slot }
        guard !apps.isEmpty else { throw CLIError("none of your session's apps are on display \(slot)") }
        let (size, origin) = try capture(.apps(apps, display: d, crop: d.bounds), to: out, scale: scale)
        return ["path": out.path, "width": Int(size.width), "height": Int(size.height), "origin": ["x": r(origin.x), "y": r(origin.y)], "scale": scale,
                "pids": Set(apps.map(\.pid)).sorted(), "display": slot]
    }
    let app = try managedApp(args)
    let pid = app.pid
    guard let d = base.on(app.display) else {
        throw CLIError("display \(app.display ?? base.primarySlot) of pid \(pid) is gone; move it with `backstage move --pid \(pid) --display \(base.primarySlot)`")
    }
    let vd = d.bounds
    if let ws = args.opt("window") {
        let w = try resolveWindow(pid, ws)
        guard let wid = w.windowID else { throw CLIError("window \(ws) has no id") }
        let (size, origin) = try capture(.window(wid, app: app, display: d), to: out, scale: scale)
        return ["path": out.path, "width": Int(size.width), "height": Int(size.height),
                "origin": ["x": r(origin.x), "y": r(origin.y)], "scale": scale,
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
    let (size, origin) = try capture(.apps([app], display: d, crop: crop), to: out, scale: scale)
    return ["path": out.path, "width": Int(size.width), "height": Int(size.height), "origin": ["x": r(origin.x), "y": r(origin.y)], "scale": scale, "pid": pid]
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
func cmdWindow(_ args: Args, app: ManagedApp) throws -> [String: Any] {
    let d = try daemonView(requireDaemon(), for: app)
    let spec = args.opt("window") ?? "0"
    let w = try resolveWindow(app.pid, spec)
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
    guard rc == .success else {
        w.setPosition(current.origin)
        throw CLIError("could not resize window \(spec) (AXError \(rc.rawValue)); it may not be resizable")
    }
    w.setPosition(target.origin)
    pump(0.1)
    guard let got = w.frame else { throw CLIError("could not read window \(spec) frame after resize") }
    var res: [String: Any] = ["ok": true, "pid": app.pid, "window": windowRef(w, index: Int(spec) ?? 0),
                              "frame": rectDict(got.offsetBy(dx: -d.bounds.minX, dy: -d.bounds.minY))]
    if abs(got.width - target.width) > 1 || abs(got.height - target.height) > 1
        || abs(got.minX - target.minX) > 1 || abs(got.minY - target.minY) > 1 {
        res["requested"] = rectDict(target.offsetBy(dx: -d.bounds.minX, dy: -d.bounds.minY))
        res["note"] = "the app or system constrained the window's frame"
    }
    return res
}

func cmdTree(_ args: Args) throws {
    let base = try requireDaemon()
    let app = try managedApp(args)
    let pid = app.pid
    let d = try daemonView(base, for: app)
    let depth = args.int("depth") ?? 40
    if args.has("json") {
        var nodes: [[String: Any]] = []
        try walkTree(pid: pid, window: args.opt("window"), maxDepth: depth) { i, _ in nodes.append(i.json(origin: d.bounds.origin)); return true }
        emit(["pid": pid, "elements": nodes])
    } else {
        var n = 0
        try walkTree(pid: pid, window: args.opt("window"), maxDepth: depth) { i, _ in
            print(i.line(origin: d.bounds.origin)); n += 1; return true
        }
        if n == 0 { print("(no windows — is the app still loading? try `backstage windows`)") }
    }
}

/// The query strings are normalized once per command, outside the AX traversal.
func matches(_ i: ElementInfo, role: String?, text: String?) -> Bool {
    if let role, !i.role.lowercased().contains(role) && i.subrole?.lowercased().contains(role) != true { return false }
    if let text, !i.label.lowercased().contains(text) { return false }
    return true
}

func cmdFind(_ args: Args) throws -> [String: Any] {
    let base = try requireDaemon()
    let app = try managedApp(args)
    let pid = app.pid
    let d = try daemonView(base, for: app)
    let role = args.opt("role")?.lowercased(), text = (args.opt("text") ?? args.pos(0))?.lowercased()
    var out: [[String: Any]] = []
    try walkTree(pid: pid, window: args.opt("window"), maxDepth: 60) { i, _ in
        if matches(i, role: role, text: text) { out.append(i.json(origin: d.bounds.origin)) }
        return out.count < 200
    }
    return ["pid": pid, "count": out.count, "elements": out]
}

func cmdWait(_ args: Args) throws -> [String: Any] {
    let role = args.opt("role"), text = args.opt("text") ?? args.pos(0)
    guard role != nil || text != nil else { throw CLIError("wait needs --text and/or --role") }
    let base = try requireDaemon()
    let app = try managedApp(args)
    let pid = app.pid
    let d = try daemonView(base, for: app)
    let normalizedRole = role?.lowercased(), normalizedText = text?.lowercased()
    let timeout = args.double("timeout") ?? 10
    let gone = args.has("gone")
    let t0 = ProcessInfo.processInfo.systemUptime
    let found: [String: Any]? = try waitFor(timeout: timeout, interval: 0.2) {
        guard app.matchesProcess else { throw CLIError("app \(pid) exited while waiting for an element") }
        var hit: ElementInfo?
        try walkTree(pid: pid, window: args.opt("window"), maxDepth: 60) { i, _ in
            if matches(i, role: normalizedRole, text: normalizedText) { hit = i; return false }
            return true
        }
        if gone { return hit == nil ? ["gone": true] : nil }
        return hit.map { $0.json(origin: d.bounds.origin) }
    }
    guard let found else { throw CLIError("timed out after \(timeout)s waiting for \(gone ? "disappearance of " : "")\(text ?? "") \(role ?? "")") }
    return ["ok": true, "element": found, "seconds": ((ProcessInfo.processInfo.systemUptime - t0) * 100).rounded() / 100]
}

func cmdList(_ args: Args) throws -> [String: Any] {
    let live = liveDaemon()
    let me = try Session.current().id
    let all = args.has("all")
    let visible = try AppStore.read(matching: { all || Session.sameID($0.session, me) || Session.isUser($0.session) })
    let apps = visible.filter { all || Session.sameID($0.session, me) }.map { a -> [String: Any] in
        let view = live?.on(a.display)
        var d: [String: Any] = ["pid": a.pid, "name": a.name, "path": a.path, "session": a.owner,
                                "windows": axWindowsSummary(a.pid, origin: view?.bounds.origin ?? .zero)]
        if let live { d["display"] = a.display ?? live.primarySlot }
        if let b = a.bundleID { d["bundleID"] = b }
        if let s = a.stdout { d["log"] = s }
        d["audio"] = a.audioMode.rawValue
        if let audio = readAudioStatus(a.pid, a.processStart) {
            d["tap"] = audio.tap
            if let reason = audio.reason { d["tapReason"] = reason }
        }
        return d
    }
    var out: [String: Any] = ["session": me, "apps": apps]
    if !all {
        let sent = visible.filter { Session.isUser($0.session) }
        if !sent.isEmpty {
            out["sentByUser"] = sent.map { ["pid": $0.pid, "name": $0.name] }
            out["note"] = "the user sent \(sent.count == 1 ? "an app" : "\(sent.count) apps") backstage (session \"user\"): "
                + "use one only if the user asked you to, with an explicit --pid; `list --all` shows their windows"
        }
    }
    let failures = recentAudioFailures(session: me, live: Set(apps.compactMap { $0["pid"] as? Int32 }))
    if !failures.isEmpty { out["audioFailures"] = failures }
    // Launches that gave up waiting for their app: the daemon registers the app here if it starts.
    let dateFormatter = ISO8601DateFormatter()
    let pending = Launching.records().filter { $0.handedOver == true && (all || Session.sameID($0.session, me)) }
        .sorted { $0.startedAt < $1.startedAt }
        .map { r -> [String: Any] in
            ["launch": r.id, "path": r.executable ?? r.bundle, "log": r.log, "session": r.session,
             "startedAt": dateFormatter.string(from: Date(timeIntervalSince1970: r.startedAt)),
             "until": dateFormatter.string(from: Date(timeIntervalSince1970: r.startedAt + Launching.handOverWindow))]
        }
    if !pending.isEmpty { out["pendingLaunches"] = pending }
    return out
}

func cmdStatus(doctor: Bool = false) throws -> [String: Any] {
    let accessibility = AXIsProcessTrusted()
    let recording = CGPreflightScreenCaptureAccess()
    var s: [String: Any] = [
        "accessibility": accessibility,
        "screenRecording": recording,
        "home": Paths.dir.path,
        "version": backstageVersion,
    ]
    let live = liveDaemon()
    if let d = live {
        var daemon: [String: Any] = ["pid": d.pid, "displayID": d.displayID, "size": ["w": Int(d.width), "h": Int(d.height)],
                                     "globalOrigin": ["x": Int(d.x), "y": Int(d.y)]]
        if let source = d.sizeSource { daemon["sizeSource"] = source }
        if let slot = displaySlot(serial: CGDisplaySerialNumber(d.displayID)) { daemon["display"] = slot }
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
        if (d.displays?.count ?? 1) > 1 || d.displays?.contains(where: { $0.reservedBy != nil }) == true { daemon["displays"] = displaysStatus(d) }
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
    let loadedSettings = Settings.load()
    var settings = loadedSettings.json()
    if let d = live { settings.merge(hotkeyState(d, wanted: loadedSettings.effectiveHotKey)) { _, new in new } }
    s["settings"] = settings
    let audio = doctor ? audioDoctor() : audioSummary(live)
    s["audio"] = audio
    var problems: [String] = []
    let audioIssues = audioProblems(audio)
    if doctor { problems += audioIssues }
    else if !audioIssues.isEmpty { s["warnings"] = audioIssues }
    if !accessibility { problems.append("Accessibility not granted: System Settings > Privacy & Security > Accessibility — enable the app that runs this CLI (your terminal / agent host).") }
    if let d = live, d.inputGuard != true {
        problems.append("The daemon's input guard isn't running (see \(Paths.log.path)), so input commands refuse to run. Check Accessibility, then `backstage stop --all`.")
    }
    if doctor {
        let leftovers = DisplayRegistry.leftovers()?.count ?? 0
        s["leftoverDisplays"] = leftovers
        if leftovers > DisplayRegistry.warnAbove {
            problems.append("ColorSync has \(leftovers) leftover backstage displays registered (older versions used a new display identity per BACKSTAGE_HOME); it slows down as that list grows. Remove them once: \(DisplayRegistry.cleanupCommand)")
        }
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
    try rejectIncompatibleDaemon()
    guard let record = try AppStore.read(matching: {
        $0.pid == pid && $0.processStart == target.processStart && Session.sameID($0.owner, target.owner)
    }).first else {
        return ["ok": true, "note": "already gone"]
    }
    let force = args.has("force")
    try record.requestTermination(force: force)
    let gone = waitFor(timeout: force ? 7 : 5) { record.matchesProcess ? nil : true } != nil
    if !gone {
        let error = force ? "app didn't exit after forced termination" :
            "app didn't quit (unsaved-changes dialog?). Inspect with screenshot/tree, or use --force"
        return ["ok": false, "pid": pid, "note": error, "error": error]
    }
    // Prune by process identity so a concurrent registration survives PID reuse.
    try AppStore.update { _ in }
    Locks.pruneAppLocks()
    return ["ok": true, "pid": pid]
}

func cmdLogs(_ args: Args) throws {
    let app = try managedApp(args)
    guard let path = app.stdout else { throw CLIError("no log for pid \(app.pid)") }
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
    var input: (app: ManagedApp, birth: UInt64, lock: StateLock)?
    defer { input?.lock.release() }
    if ["press", "focus", "action", "set", "click", "hover", "drag", "scroll", "type", "key", "menu", "window"].contains(cmd) {
        let app = try managedApp(args)
        guard let birth = app.processStart ?? processBirth(app.pid) else {
            throw CLIError("pid \(app.pid) is no longer a live managed app in this session")
        }
        let lock = try Locks.app(app)
        // A handoff may have completed while this input command was waiting for the app lock.
        guard let checked = try AppStore.read(matching: {
            $0.pid == app.pid && $0.processStart == app.processStart && Session.sameID($0.owner, app.owner)
        }).first, app.processStart != nil || processBirth(app.pid) == birth else {
            throw CLIError("pid \(app.pid) is no longer a live managed app in this session")
        }
        if cmd != "window" { try requireInputGuard() }
        input = (checked, birth, lock)
    }
    func inputTarget() throws -> (app: ManagedApp, birth: UInt64) {
        guard let input, processBirth(input.app.pid) == input.birth else {
            throw CLIError("managed app exited before it could receive input")
        }
        return (input.app, input.birth)
    }
    func inputOnDisplay() throws -> (pid: pid_t, birth: UInt64, daemon: DaemonInfo) {
        let base = try requireDaemon()
        let (app, birth) = try inputTarget()
        return (app.pid, birth, try daemonView(base, for: app))
    }

    switch cmd {
    case "__menu-thumbnail":
        try runMenuThumbnail(args)
    case "__guard-selftest":
        let result = guardSelfTest(rejectedHelperPID: args.int("pid").flatMap(pid_t.init(exactly:)))
        emit(result)
        if result["ok"] as? Bool != true { exit(1) }
    case "__audio-taps":
        // Diagnostics: the tap manager alone (no display), muting what apps.json and pending
        // launch records name, publishing to $BACKSTAGE_HOME/audio, until SIGTERM/SIGINT.
        guard #available(macOS 14.2, *) else { throw CLIError("needs macOS 14.2") }
        try Paths.ensure()
        let taps = AudioTapManager(log: { eprint($0) }, quit: { pid, birth, _ in if processBirth(pid) == birth { kill(pid, SIGTERM) } })
        if let failure = taps.start() { throw CLIError(failure) }
        eprint("audio taps up")
        var last: [AudioRegistryEntry] = []
        var stop = false
        for sig in [SIGTERM, SIGINT] { signal(sig) { _ in exit(0) } }
        while !stop {
            let entries = AppStore.load().compactMap(AudioRegistryEntry.init)
            if entries != last { last = entries; taps.updateRegistry(entries) }
            pump(0.25)
            stop = FileManager.default.fileExists(atPath: Paths.dir.appendingPathComponent("audio-taps.stop").path)
        }
        taps.shutdown()
    case "__inaudible-check":
        // Tests: what `launch` would do about an app's sound (no launch, no daemon).
        guard let target = args.pos(0) else { throw CLIError("usage: backstage __inaudible-check <app|path>") }
        let url = try resolveApp(target)
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard let exe = isDir.boolValue ? Bundle(url: url)?.executableURL : url else { throw CLIError("no executable in \(url.path)") }
        var out: [String: Any] = ["executable": exe.resolvingSymlinksInPath().path]
        if let library = InaudibleLibrary.locate() {
            let check = inaudibleEligibility(exe, library: library)
            out["library"] = library.path
            out["eligible"] = check.eligible
            out["detail"] = check.detail
        } else {
            out["library"] = NSNull(); out["eligible"] = false
        }
        out["audio"] = (try? planAudio(args, executable: exe, name: url.lastPathComponent).mode.rawValue) ?? NSNull()
        emit(out)
    case "__send-backstage":
        let result = try cmdSendBackstage(args)
        emit(result)
        if result["ok"] as? Bool != true { exit(1) }
    case "__send-refusal": emit(cmdSendRefusal(args))
    case "settings": emit(try cmdSettings(args))
    case "__dock-restore":
        // Tests: give a managed app its Dock tile back as `show` does, without moving or activating it.
        let app = try managedApp(args)
        emit(["ok": true, "pid": app.pid, "dock": restoreDock(app.pid), "type": LaunchServices.applicationType(app.pid) ?? "unknown"])
    case "__daemon":
        try Paths.ensure()
        let d = try Daemon()
        Daemon.shared = d
        try d.run()
    case "help", "-h", "--help": print(usage)
    case "version", "--version": print("backstage \(backstageVersion)")
    case "start": let d = try ensureDaemon(); emit(["ok": true, "pid": d.pid, "displayID": d.displayID])
    case "stop":
        let result = try args.has("all") ? stopAll() : stopSession()
        emit(result)
        if result["ok"] as? Bool == false { exit(1) }
    case "status", "doctor": emit(try cmdStatus(doctor: cmd == "doctor"))
    case "cleanup-displays": emit(try cmdCleanupDisplays())
    case "__menu-render": emit(try runMenuRender(args))
    case "move": emit(try cmdMove(args))
    case "audio": emit(try cmdAudio(args))
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
    case "window": emit(try cmdWindow(args, app: try inputTarget().app))
    case "windows":
        let base = try requireDaemon()
        let app = try managedApp(args)
        let d = try daemonView(base, for: app)
        emit(["pid": app.pid, "windows": axWindowsSummary(app.pid, origin: d.bounds.origin)])
    case "screenshot", "shot": emit(try cmdScreenshot(args))
    case "tree": try cmdTree(args)
    case "find": emit(try cmdFind(args))
    case "wait": emit(try args.has("sound") ? cmdWaitSound(args) : cmdWait(args))
    case "press", "focus", "action", "set":
        let (app, birth) = try inputTarget()
        let pid = app.pid
        guard let ref = args.pos(0) else { throw CLIError("usage: backstage \(cmd) <ref>") }
        let e = try resolveRef(pid, ref)
        _ = try inputTarget()
        let rc: AXError
        switch cmd {
        case "press": rc = AXUIElementPerformAction(e, kAXPressAction as CFString)
        case "focus":
            focusWindowOf(e, pid: pid, birth: birth)
            _ = try inputTarget()
            rc = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "action":
            guard let a = args.pos(1) else { throw CLIError("usage: backstage action <ref> <AXAction>") }
            rc = AXUIElementPerformAction(e, (a.hasPrefix("AX") ? a : "AX" + a) as CFString)
        default:
            guard let v = args.pos(1) else { throw CLIError("usage: backstage set <ref> <value>") }
            let cur = e.attr(kAXValueAttribute)
            let val: CFTypeRef
            if cur is NSNumber, let number = Double(v) {
                guard number.isFinite else { throw CLIError("numeric element values must be finite") }
                val = NSNumber(value: number)
            } else {
                val = v as NSString
            }
            _ = try inputTarget()
            rc = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, val)
        }
        guard rc == .success else { throw CLIError("\(cmd) failed: AXError \(rc.rawValue)\(rc == .actionUnsupported ? " (unsupported — try `click --ref \(ref)`)" : "")") }
        pump(0.15)
        emit(["ok": true])
    case "click":
        let (pid, birth, d) = try inputOnDisplay()
        var res: [String: Any]
        var location: CGPoint?
        if let ref = args.opt("ref") {
            // Element click: AXPress when the element supports it (most reliable), else mouse at its center.
            let e = try resolveRef(pid, ref)
            location = try? elementCenter(e)
            if !args.has("right") && !args.has("double") && !args.has("raw") && e.actions.contains(kAXPressAction as String),
               processBirth(pid) == birth,
               AXUIElementPerformAction(e, kAXPressAction as CFString) == .success {
                res = ["ok": true, "via": "ax-press"]
            } else {
                guard let location, d.bounds.contains(location) else { throw CLIError("element has no clickable center on the agent display") }
                res = try doClick(global: location, pid: pid, birth: birth, args: args)
            }
        } else {
            let p = try point(args, 0, d.bounds)
            location = p
            res = try doClick(global: p, pid: pid, birth: birth, args: args)
        }
        if let location, let x = Int(exactly: (location.x - d.bounds.minX).rounded()),
           let y = Int(exactly: (location.y - d.bounds.minY).rounded()) {
            res["at"] = ["x": x, "y": y]
        }
        pump(0.15)
        emit(res)
    case "hover":
        let (pid, birth, d) = try inputOnDisplay()
        let p = try point(args, 0, d.bounds)
        guard let hit = hitTest(p, pids: [pid]) else { throw CLIError("no window of pid \(pid) at that point") }
        if let w = axApp(pid).windows.first(where: { $0.windowID == hit.windowID }), (w.attr(kAXMainAttribute) as? Bool) != true {
            focusWindowOf(w, pid: pid, birth: birth)
        }
        primeActivation(pid, birth: birth)
        // A short approach path so enter/move handlers see motion, not a single teleport.
        for i in stride(from: 4, through: 0, by: -1) {
            try postMove(to: CGPoint(x: p.x - CGFloat(i * 3), y: p.y), hit: hit, birth: birth); usleep(15_000)
        }
        pump(0.1); emit(["ok": true])
    case "drag":
        let (pid, birth, d) = try inputOnDisplay()
        let a = try point(args, 0, d.bounds), b = try point(args, 2, d.bounds)
        guard let hit = hitTest(a, pids: [pid]) else { throw CLIError("no window of pid \(pid) at start point") }
        try postDrag(from: a, to: b, hit: hit, steps: args.int("steps") ?? 20, birth: birth); pump(0.15); emit(["ok": true])
    case "scroll":
        let (pid, birth, d) = try inputOnDisplay()
        let p = try point(args, 0, d.bounds)
        guard let hit = hitTest(p, pids: [pid]) else { throw CLIError("no window of pid \(pid) at that point") }
        try postScroll(at: p, hit: hit, dx: Int32(args.int("dx") ?? 0), dy: Int32(args.int("dy") ?? -100), birth: birth); pump(0.15); emit(["ok": true])
    case "type":
        let (app, birth) = try inputTarget()
        let pid = app.pid
        guard let text = args.pos(0) else { throw CLIError("usage: backstage type <text> [--ref R]") }
        try focusRef(args.opt("ref"), pid: pid, birth: birth)
        try postText(pid: pid, text: text, birth: birth); pump(0.1); emit(["ok": true, "chars": text.count])
    case "key":
        let (app, birth) = try inputTarget()
        let pid = app.pid
        let keys = try args.positional.map(parseCombo)
        try focusRef(args.opt("ref"), pid: pid, birth: birth)
        try postKeys(pid: pid, keys: keys, birth: birth)
        pump(0.1); emit(["ok": true])
    case "menu":
        let pid = try inputTarget().app.pid
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
