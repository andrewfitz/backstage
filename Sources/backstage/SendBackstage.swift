import Foundation
import AppKit
import ApplicationServices

// MARK: - Send Front Window Backstage
//
// The reverse of Show on My Screen: the user sends the app of their frontmost window to the
// hidden display (the hotkey or the menu bar). backstage manages whole processes, so every
// window of the app goes. The app is registered to the `user` owner (Session.user), its windows
// are moved to the agent display, the daemon mutes it with a tap (it's already running, so it
// can't be made inaudible: screen sharing can still hear it), and keyboard focus goes to the app
// the user was using before. Its Dock tile stays: the app was launched normally.
//
// The daemon runs `backstage __send-backstage --pid P --focus-to N` as a child for each press,
// as it does for menu thumbnails: AX calls into a busy app and lock waits never hold up its
// guard loop, and the test hook is literally the same code path.

/// Never sent backstage: parts of macOS, and apps the user needs in front of them to stay in
/// control (the terminal or agent host that runs the agents, remote-control tools). Bundle IDs
/// match exactly, or by prefix for entries ending in ".".
let sendRefusedSystemIDs = [
    "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
    "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.WindowManager", "com.apple.Spotlight",
    "com.apple.SecurityAgent", "com.apple.screencaptureui", "com.apple.UserNotificationCenter",
    "com.apple.coreservices.uiagent", "com.apple.windowserver",
]
let sendRefusedHostIDs = [
    "com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.anthropic.", "com.openai.",
    "tv.parsec.", "com.parsec.", "dev.warp.", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    "co.zeit.hyper", "dev.herdr.",
]
let sendRefusedHostNames: Set<String> = [
    "terminal", "ghostty", "iterm", "iterm2", "herdr", "claude", "codex", "chatgpt", "parsec", "warp", "kitty",
    "alacritty", "wezterm",
]

private func idMatches(_ id: String, _ entries: [String]) -> Bool {
    let lower = id.lowercased()
    return entries.contains { $0.hasSuffix(".") ? lower.hasPrefix($0.lowercased()) : lower == $0.lowercased() }
}

/// Why an app must not be sent backstage, from what it is (not its state), or nil.
/// BACKSTAGE_TEST_REFUSE (tests only) adds one bundle-ID prefix to the host list.
func sendRefusal(bundleID: String?, name: String?, path: String?,
                 env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let display = name ?? bundleID ?? "this app"
    if let id = bundleID, idMatches(id, sendRefusedSystemIDs) { return "\(display) is part of macOS" }
    if let path, path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") {
        return "\(display) is part of macOS"
    }
    var hosts = sendRefusedHostIDs
    if let extra = env["BACKSTAGE_TEST_REFUSE"], !extra.isEmpty { hosts.append(extra.hasSuffix(".") ? extra : extra + ".") }
    let host = bundleID.map { idMatches($0, hosts) } == true || name.map { sendRefusedHostNames.contains($0.lowercased()) } == true
    return host ? "\(display) runs your terminal, agents or remote control; you need it on your screen" : nil
}

/// `backstage __send-refusal --bundle-id ID --name N --path P` (tests): the static rules alone.
func cmdSendRefusal(_ args: Args) -> [String: Any] {
    let why = sendRefusal(bundleID: args.opt("bundle-id"), name: args.opt("name"), path: args.opt("path"))
    return ["ok": true, "refused": why.map { $0 as Any } ?? NSNull()]
}

private func sendLog(_ s: String) {
    appendLogLine("\(ISO8601DateFormatter().string(from: Date())) send backstage: \(s)\n", to: Paths.log)
}

/// Adopt the app `pid` as a user-sent managed app. `focusTo` is the app to give keyboard focus to
/// if `pid` is frontmost (the daemon passes the app the user used before it). Refusals come back
/// as `ok: false` with `refused`; nothing is changed then.
func sendBackstage(pid: pid_t, focusTo: pid_t?, display slot: Int? = nil) -> [String: Any] {
    var name = processPath(pid).map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
    func refuse(_ why: String) -> [String: Any] {
        sendLog("refused pid \(pid) (\(name)): \(why)")
        return ["ok": false, "pid": pid, "name": name, "refused": why]
    }
    guard let d = liveDaemon(), !d.protocolMismatch, d.stopping != true else { return refuse("the backstage daemon isn't running") }
    guard d.audio == true else { return refuse("backstage can't mute apps right now (\(d.audioReason ?? "audio unavailable"))") }
    guard let birth = processBirth(pid), let app = NSRunningApplication(processIdentifier: pid),
          !app.isTerminated, processBirth(pid) == birth else {
        return refuse("no app with that process ID")
    }
    name = app.localizedName ?? name
    let path = app.bundleURL?.path ?? app.executableURL?.path ?? processPath(pid)
    if pid == getpid() || pid == d.pid || processPath(pid).map({ ($0 as NSString).lastPathComponent == "backstage" }) == true {
        return refuse("that's backstage itself")
    }
    if let why = sendRefusal(bundleID: app.bundleIdentifier, name: app.localizedName, path: path) { return refuse(why) }
    guard app.activationPolicy == .regular else { return refuse("\(name) is a menu bar or background app") }
    // The terminal or agent host the daemon (or this command) runs under.
    if responsiblePid(d.pid) == pid || responsiblePid(getpid()) == pid {
        return refuse("\(name) runs backstage itself; you need it on your screen")
    }
    if AppStore.load().contains(where: { $0.pid == pid }) { return refuse("\(name) is already backstage") }
    let own = Set([d.displayID] + (d.displays ?? []).map { $0.displayID })
    let others = activeDisplays().filter { isOurDisplay($0) && !own.contains($0) }.map { CGDisplayBounds($0) }
    if onscreenWindows().contains(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && others.contains(where: cgBounds($0).intersects) }) {
        return refuse("\(name) is on another backstage display")
    }
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 1)
    guard let windows = try? ax.readElements(kAXWindowsAttribute) else { return refuse("\(name) isn't answering accessibility requests") }
    let open = windows.filter { ($0.attr(kAXMinimizedAttribute) as? Bool) != true }
    guard !open.isEmpty else { return refuse("\(name) has no open window") }
    if open.contains(where: { ($0.attr("AXFullScreen") as? Bool) == true }) {
        return refuse("\(name) has a full-screen window; leave full screen first")
    }

    // Never wait on a lock: a busy launch, stop or show elsewhere means "try again".
    let lifecycle: StateLock, owner: StateLock
    do {
        lifecycle = try StateLock("lifecycle.lock", nonblocking: true, shared: true)
        owner = try Locks.session(Session.user, nonblocking: true)
    } catch {
        return refuse("backstage is busy (a stop or show is in progress); try again")
    }
    defer { owner.release(); lifecycle.release() }
    guard let current = liveDaemon(), current.pid == d.pid, current.processStart == d.processStart,
          current.startedAt == d.startedAt, current.stopping != true, current.audio == true else {
        return refuse("the backstage daemon changed while checking the app")
    }

    let record = ManagedApp(pid: pid, name: name, bundleID: app.bundleIdentifier, path: path ?? "",
                            launchedAt: Date().timeIntervalSince1970, stdout: nil, processStart: birth,
                            agent: nil, agentPID: nil, session: Session.user, audio: AudioMode.muted.rawValue,
                            display: slot == current.primarySlot ? nil : slot)
    // The display the daemon chose (it created it if needed); the primary if it's gone meanwhile.
    guard let target = current.on(slot) ?? liveDaemon()?.on(slot) else { return refuse("display \(slot ?? 0) isn't running") }
    let placement: StateLock
    do {
        placement = try Locks.app(record, nonblocking: true)
        try AppStore.update { apps in
            guard record.matchesProcess else { throw CLIError("the app exited") }
            guard !apps.contains(where: { $0.pid == pid }) else { throw CLIError("the app is already backstage") }
            apps.append(record)
        }
    } catch {
        return refuse("couldn't register \(name): \(error)")
    }
    defer { placement.release() }
    lifecycle.release()

    let vd = target.bounds
    func released() -> Bool {
        !AppStore.load().contains { $0.pid == pid && $0.processStart == birth && Session.isUser($0.session) }
    }
    var focus = "unchanged"
    if !released(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
        focus = handFocus(awayFrom: pid, to: focusTo)
    }
    var placed: [CGRect] = []
    for w in open {
        guard !released() else { break }
        placed.append(placeBeside(w, display: vd, avoiding: placed))
    }
    let contained = waitFor(timeout: 1.5) { () -> Bool? in
        // Given back already (its sound couldn't be muted): leave its windows where they went.
        if released() { return false }
        guard let current = try? ax.readElements(kAXWindowsAttribute) else { return nil }
        let ok = current.allSatisfy { ($0.attr(kAXMinimizedAttribute) as? Bool) == true || $0.frame.map { vd.contains($0) } == true }
        if !ok, !released() { adoptWindows(pid: pid, display: vd) }
        return ok ? true : nil
    } ?? false
    // The daemon taps it on its next registry read; it may release the app during this wait.
    let tap = waitFor(timeout: 2) {
        released() ? "" : readAudioStatus(pid, birth)?.tap
    } ?? "pending"
    guard processBirth(pid) == birth else { return refuse("\(name) exited while being sent backstage") }
    if released() {
        if app.isHidden { _ = app.unhide() }
        let why = readAudioStatus(pid, birth)?.reason ?? "it was given back"
        sendLog("pid \(pid) (\(name)) was released: \(why)")
        return ["ok": false, "pid": pid, "name": name, "refused": "\(name) was given back to your screen: \(why)"]
    }
    // A hidden app (the test fixture) shows its windows once they're on the agent display.
    if contained, app.isHidden { _ = app.unhide() }
    sendLog("sent pid \(pid) (\(name)) backstage; windows \(contained ? "on the agent display" : "not all placed yet"), focus \(focus), tap \(tap)")
    var out: [String: Any] = [
        "ok": true, "pid": pid, "name": name, "session": Session.user, "audio": AudioMode.muted.rawValue, "tap": tap,
        "windows": axWindowsSummary(pid, origin: vd.origin), "focus": focus,
        "dock": "visible (the app was opened normally, so its Dock tile stays)",
    ]
    if let id = app.bundleIdentifier { out["bundleID"] = id }
    if !contained { out["warning"] = "not every window was on the agent display yet; the daemon keeps moving them" }
    return out
}

/// Give keyboard focus to `candidate` (else Finder), so focus never stays on the app being sent.
private func handFocus(awayFrom pid: pid_t, to candidate: pid_t?) -> String {
    func usable(_ a: NSRunningApplication?) -> NSRunningApplication? {
        guard let a, !a.isTerminated, a.processIdentifier != pid, a.activationPolicy == .regular, !a.isHidden else { return nil }
        return a
    }
    guard let next = usable(candidate.flatMap { NSRunningApplication(processIdentifier: $0) })
            ?? usable(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first) else { return "unchanged" }
    AXUIElementSetAttributeValue(axApp(next.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if !next.isActive { next.activate() }
    let moved = waitFor(timeout: 0.5) { NSWorkspace.shared.frontmostApplication?.processIdentifier != pid ? true : nil } != nil
    let who = next.localizedName ?? "pid \(next.processIdentifier)"
    return moved ? "handed to \(who)" : "asked \(who) to take it, unconfirmed (the daemon hands it back if the app keeps it)"
}

/// `backstage __send-backstage --pid P [--focus-to N] [--display D]`: the daemon's child for the hotkey and
/// menu, and the test hook (BACKSTAGE_TEST_HOOKS=1) for the same path.
func cmdSendBackstage(_ args: Args) throws -> [String: Any] {
    let fromDaemon = liveDaemon().map { $0.pid == getppid() } ?? false
    guard fromDaemon || ProcessInfo.processInfo.environment["BACKSTAGE_TEST_HOOKS"] == "1" else {
        throw CLIError("internal command: the menu bar's Send Front Window Backstage runs it (tests set BACKSTAGE_TEST_HOOKS=1)")
    }
    guard let pid = args.opt("pid").flatMap(pid_t.init), pid > 0 else {
        throw CLIError("usage: backstage __send-backstage --pid P [--focus-to N]")
    }
    let focusTo = args.opt("focus-to").flatMap(pid_t.init)
    return sendBackstage(pid: pid, focusTo: focusTo, display: args.opt("display").flatMap(Int.init))
}

/// Give a user-sent app back without quitting it: out of the registry (the daemon removes its
/// tap, so it's audible again) and its windows onto the user's main display. Used when it
/// didn't quit at shutdown (an unsaved-changes dialog) or its sound couldn't be muted: the
/// user's work is never force-quit.
func releaseToUser(_ record: ManagedApp, log: (String) -> Void) {
    var removed = false
    do {
        try AppStore.update { apps in
            guard let index = apps.firstIndex(where: {
                $0.pid == record.pid && $0.processStart == record.processStart && Session.isUser($0.session)
            }) else { return }
            apps.remove(at: index)
            removed = true
        }
    } catch { log("couldn't release pid \(record.pid) to the user: \(error)"); return }
    guard removed else { return }
    Placement.set(record, slot: nil)
    if record.matchesProcess, let target = userDisplayBounds().first {
        for (i, w) in axApp(record.pid).windows.enumerated() {
            guard record.matchesProcess else { break }
            let size = w.size ?? CGSize(width: 600, height: 400)
            w.setPosition(CGPoint(x: target.midX - size.width / 2 + CGFloat(i * 30),
                                  y: max(target.minY + 60, target.midY - size.height / 2 + CGFloat(i * 30))))
        }
    }
    log("gave pid \(record.pid) (\(record.name)), which you sent backstage, back to your screen")
}

// MARK: - daemon side

extension Daemon {
    /// The hotkey or the menu: send the frontmost app's process backstage, in a child.
    /// `target` replaces the frontmost app (the daemon's test trigger only).
    /// `to`: "new" or a display number (the menu's Send Front Window To); nil: the display the
    /// user's sent apps are on, else the primary.
    func sendFrontWindowBackstage(from origin: String, target: NSRunningApplication? = nil, to want: String? = nil) {
        guard !stopping, !shutdownRequested else { return }
        guard !sendInFlight else { log("send backstage (\(origin)): already sending one; ignored"); return }
        guard let front = target ?? NSWorkspace.shared.frontmostApplication, !front.isTerminated else {
            log("send backstage (\(origin)): refused: no frontmost app")
            statusMenu?.sendCue(text: "Nothing to send backstage", success: false)
            return
        }
        var executable = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &executable, UInt32(executable.count)) > 0 else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: String(cString: executable))
        let slot: Int
        do { slot = try want.map { try grantDisplay($0, session: Session.user, override: true) } ?? userDisplay() }
        catch {
            log("send backstage (\(origin)): refused: \(error)")
            statusMenu?.sendCue(text: "Can't send \(front.localizedName ?? "the app") backstage: \(error)", success: false)
            return
        }
        var arguments = ["__send-backstage", "--pid", String(front.processIdentifier)]
        if let next = nextUserApp(excluding: front.processIdentifier) { arguments += ["--focus-to", String(next.processIdentifier)] }
        if slot != display.slot { arguments += ["--display", String(slot)] }
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { log("send backstage: couldn't start: \(error)"); return }
        sendInFlight = true
        log("send backstage (\(origin)): pid \(front.processIdentifier) (\(front.localizedName ?? "?"))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            killer.cancel()
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                self.sendInFlight = false
                let name = result["name"] as? String ?? front.localizedName ?? "the app"
                if result["ok"] as? Bool == true {
                    self.reloadManaged(now: ProcessInfo.processInfo.systemUptime)
                    // Focus must not stay on the app that was sent.
                    if let now = NSWorkspace.shared.frontmostApplication, self.managed.contains(now.processIdentifier),
                       let back = self.lastUserApp, !back.isTerminated {
                        self.log("send backstage: focus was still on pid \(now.processIdentifier); handing it to \(back.localizedName ?? "?")")
                        back.activate()
                    }
                    self.statusMenu?.update(apps: self.managed.count)
                    self.statusMenu?.sendCue(text: "Sent \(name) backstage", success: true)
                } else {
                    let why = result["refused"] as? String ?? result["error"] as? String ?? "it didn't finish"
                    self.statusMenu?.sendCue(text: "Can't send \(name) backstage: \(why)", success: false)
                }
            }
        }
    }

    /// TEST ONLY (BACKSTAGE_TEST_SEND_REQUESTS=1 in the daemon's environment): a pid written to
    /// $BACKSTAGE_HOME/send-request is sent as if it were the frontmost app, through the same
    /// daemon path as the hotkey (child, result, cue). Lets tests run it without pressing keys.
    func checkTestSendRequest() {
        let url = Paths.dir.appendingPathComponent("send-request")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        // "PID" (Send Front Window Backstage) or "PID DISPLAY" (Send Front Window To).
        let parts = text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        guard let pid = parts.first.flatMap(pid_t.init),
              let app = NSRunningApplication(processIdentifier: pid) else { log("send backstage (test): no app for '\(text)'"); return }
        sendFrontWindowBackstage(from: "test", target: app, to: parts.dropFirst().first)
        // "move-request": "PID DISPLAY", the menu's Move to, through the same daemon path.
    }

    /// TEST ONLY (BACKSTAGE_TEST_SEND_REQUESTS=1): "PID DISPLAY" in $BACKSTAGE_HOME/move-request
    /// moves that managed app as the menu's Move to does; the result goes to move-result.
    func checkTestMoveRequest() {
        let url = Paths.dir.appendingPathComponent("move-request")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        let parts = text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        let result: String
        if parts.count == 2, let pid = pid_t(parts[0]), let record = registry.first(where: { $0.pid == pid }) {
            result = moveApp(record, to: parts[1]) ?? "ok"
        } else {
            result = "no managed app for '\(text)'"
        }
        try? result.write(to: Paths.dir.appendingPathComponent("move-result"), atomically: true, encoding: .utf8)
    }

    /// The app the user used most recently before `pid`: where focus goes when `pid` is sent.
    func nextUserApp(excluding pid: pid_t) -> NSRunningApplication? {
        recentUserApps.first {
            !$0.isTerminated && $0.processIdentifier != pid && $0.processIdentifier != getpid() && !$0.isHidden
                && $0.activationPolicy == .regular && !managed.contains($0.processIdentifier)
        }
    }

    /// Remember the user's app switches (most recent first), for `nextUserApp`.
    func noteUserApp(_ app: NSRunningApplication) {
        recentUserApps.removeAll { $0.processIdentifier == app.processIdentifier || $0.isTerminated }
        recentUserApps.insert(app, at: 0)
        if recentUserApps.count > 12 { recentUserApps.removeLast(recentUserApps.count - 12) }
    }
}
