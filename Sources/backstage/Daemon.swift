import Foundation
import AppKit
import ApplicationServices

/// Place a window inside the agent display, cascading by `slot`, shrinking it if it doesn't fit.
func placeOnAgentDisplay(_ w: AXUIElement, display b: CGRect, slot: Int) {
    let margin: CGFloat = 40, top: CGFloat = 60
    let off = CGFloat(slot % 8) * 30
    let insetX = min(margin, b.width / 10), insetY = min(top, b.height / 10)
    var x = insetX + off, y = insetY + off
    if let s = w.size {
        let maxW = b.width - insetX * 2, maxH = b.height - insetY * 2
        x = min(x, b.width - min(s.width, maxW) - insetX)
        y = min(y, b.height - min(s.height, maxH) - insetY)
        if s.width > maxW || s.height > maxH { w.setSize(CGSize(width: min(s.width, maxW), height: min(s.height, maxH))) }
    }
    w.setPosition(CGPoint(x: b.minX + x, y: b.minY + y))
}

/// Place a newly appeared window to the right of everything already on the agent display
/// (so it doesn't hide other windows from screenshots); cascade if there's no room.
func placeBeside(_ w: AXUIElement, display b: CGRect) {
    let me = w.windowID
    let occupied = onscreenWindows()
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowNumber as String] as? CGWindowID) != me }
        .map(cgBounds)
        .filter { b.intersects($0) && $0.width > 50 && $0.height > 50 }
    let size = w.size ?? CGSize(width: 400, height: 300)
    let x = max((occupied.map { $0.maxX }.max() ?? b.minX) + 20, b.minX + 40)
    if x + size.width <= b.maxX - 10, size.height <= b.height - 70 {
        w.setPosition(CGPoint(x: x, y: b.minY + 60))
    } else {
        placeOnAgentDisplay(w, display: b, slot: occupied.count)
    }
}

/// Move every window of `pid` that is not already on the agent display onto it.
@discardableResult
func adoptWindows(pid: pid_t, display b: CGRect, slotBase: Int = 0) -> Int {
    var moved = 0
    for (i, w) in axApp(pid).windows.enumerated() {
        guard let f = w.frame else { continue }
        if b.contains(f) { continue }
        if (w.attr(kAXMinimizedAttribute) as? Bool) == true { continue }
        placeOnAgentDisplay(w, display: b, slot: slotBase + i)
        moved += 1
    }
    return moved
}

final class Daemon {
    let owner: StateLock
    let startedAt = Date().timeIntervalSince1970
    let display: AgentDisplay
    var lastUserApp: NSRunningApplication?
    var managed: Set<pid_t> = []
    var screens: [CGRect] = []
    var idleSince = ProcessInfo.processInfo.systemUptime
    let idleTimeout: Double
    var stopping = false
    var signalSources: [DispatchSourceSignal] = []
    var statusMenu: StatusMenu?
    var nextMenuUpdate = 0.0

    init() throws {
        owner = try StateLock("daemon.lock", nonblocking: true)
        let env = ProcessInfo.processInfo.environment
        guard let w = UInt32(env["BACKSTAGE_WIDTH"] ?? "1920"), w > 0,
              let h = UInt32(env["BACKSTAGE_HEIGHT"] ?? "1200"), h > 0 else {
            throw CLIError("BACKSTAGE_WIDTH and BACKSTAGE_HEIGHT must be positive integers")
        }
        guard let timeout = Double(env["BACKSTAGE_IDLE_TIMEOUT"] ?? "1800"),
              timeout.isFinite, timeout >= 0, timeout < Double(Int.max) else {
            throw CLIError("BACKSTAGE_IDLE_TIMEOUT must be a finite nonnegative number of seconds")
        }
        idleTimeout = timeout
        display = try AgentDisplay(width: w, height: h)
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: Paths.log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: Paths.log, atomically: true, encoding: .utf8) }
    }

    func run() throws -> Never {
        // Wait for the display to come online, then park it.
        guard waitFor(timeout: 5, { activeDisplays().contains(display.id) ? true : nil }) != nil, display.park() else {
            throw CLIError("could not bring the agent display online and park it")
        }
        pump(0.5)
        screens = userDisplayBounds()

        lastUserApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if self.managed.contains(app.processIdentifier) {
                self.log("managed app \(app.processIdentifier) took focus; handing focus back to \(self.lastUserApp?.bundleIdentifier ?? "?")")
                if let back = self.lastUserApp, !back.isTerminated { back.activate() }
            } else {
                self.lastUserApp = app
            }
        }
        // Monitor arrangement changes (user plugs in a screen): re-park.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async { Daemon.shared?.scheduleRepark() }
        }, nil)

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.shutdown(reason: "signal \(sig)") }
            s.resume()
            signalSources.append(s)
        }

        try writeInfo()
        log("daemon up pid=\(getpid()) display=\(display.id) bounds=\(display.bounds)")
        // Menu bar indicator: the daemon runs as an accessory app (no Dock icon, never activates).
        if ProcessInfo.processInfo.environment["BACKSTAGE_MENUBAR"] != "off" {
            NSApplication.shared.setActivationPolicy(.accessory)
            statusMenu = StatusMenu(daemon: self)
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            autoreleasepool { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keep guarding windows while a menu is open
        if statusMenu != nil { NSApplication.shared.run() } else { RunLoop.main.run() }
        exit(0)
    }

    static var shared: Daemon?

    var reparkPending = false
    func scheduleRepark() {
        guard !reparkPending else { return }
        reparkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.reparkPending = false
            self.repark()
        }
    }
    func repark() {
        guard !stopping else { return }
        // Monitor unplugged / turned off: the agent display would become the user's only screen
        // and their windows would migrate onto it. Bail out so it disappears.
        screens = userDisplayBounds()
        if screens.isEmpty { shutdown(reason: "no user display left"); return }
        let u = screens.reduce(CGRect.null) { $0.union($1) }
        let b = display.bounds
        if b.minX != u.maxX || b.minY != u.maxY {
            guard display.park() else { shutdown(reason: "failed to re-park display"); return }
            log("re-parked display at \(display.bounds)")
        }
        do { try writeInfo() } catch { log("cannot update display state: \(error)") }
    }

    func writeInfo() throws {
        let b = display.bounds
        try writeJSON(Paths.daemon, DaemonInfo(pid: getpid(), displayID: display.id, x: b.minX, y: b.minY, width: b.width, height: b.height, startedAt: startedAt, processStart: processBirth(getpid())))
    }

    // Each registry update atomically replaces the file. Read and decode it only after replacement.
    struct RegistryVersion: Equatable {
        let inode: ino_t
        let seconds: Int
        let nanoseconds: Int

        init?() {
            var metadata = stat()
            guard stat(Paths.apps.path, &metadata) == 0 else { return nil }
            inode = metadata.st_ino
            seconds = metadata.st_mtimespec.tv_sec
            nanoseconds = metadata.st_mtimespec.tv_nsec
        }
    }
    var registryVersion: RegistryVersion?
    var registryUnreadable = false
    var registry: [ManagedApp] = []
    func reloadManaged(now: Double) {
        let version = RegistryVersion()
        if version != registryVersion || ((registryUnreadable || nextReload == 0) && now >= nextReload) {
            do {
                registry = try AppStore.read(allowMissing: !registryUnreadable && !registry.contains { $0.matchesProcess })
                registryUnreadable = false
            } catch {
                if !registryUnreadable { log("cannot read app registry: \(error)") }
                registryUnreadable = true
            }
            registryVersion = version
        } else if now < nextReload { return }
        nextReload = now + 0.25
        registry.removeAll { !$0.matchesProcess }
        managed = Set(registry.map { $0.pid })
        for pid in managed where observers[pid] == nil { observe(pid) }
        for pid in observers.keys where !managed.contains(pid) {
            if let o = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            }
        }
    }

    var observers: [pid_t: AXObserver] = [:]

    func observe(_ pid: pid_t) {
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, _ in
            guard let d = Daemon.shared, !d.stopping else { return }
            d.windowAppeared(element)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let app = axApp(pid)
        // Registration fails while the app is still starting up; retry on a later tick until it sticks.
        let rc = AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, nil)
        guard rc == .success || rc == .notificationAlreadyRegistered else { return }
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowMovedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        log("observing pid \(pid)")
    }

    func windowAppeared(_ element: AXUIElement) {
        // Notification element may be the window or something inside it.
        var w = element
        if w.role != "AXWindow", let win = w.attr(kAXWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() { w = win as! AXUIElement }
        guard w.role == "AXWindow", managed.contains(w.pid), let f = w.frame else { return }
        let b = display.bounds
        if !b.contains(f) && (w.attr(kAXMinimizedAttribute) as? Bool) != true {
            // Get it off the user's screen with one AX call first, then find it a tidy spot.
            w.setPosition(CGPoint(x: b.minX + 40, y: b.minY + 60))
            placeBeside(w, display: b)
            log("observer moved new window '\(w.str(kAXTitleAttribute) ?? "")' of pid \(w.pid)")
        }
    }

    var nextReload = 0.0
    var pendingShutdown: String?

    func tick() {
        guard !stopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let reason = pendingShutdown { shutdown(reason: reason); return }
        reloadManaged(now: now)
        if let m = statusMenu, now >= nextMenuUpdate {
            nextMenuUpdate = now + 0.5
            m.update(apps: managed.count)
        }
        let b = display.bounds

        // 1. Keep managed windows off the user's screens.
        if !managed.isEmpty {
            idleSince = ProcessInfo.processInfo.systemUptime
            var offenders: Set<pid_t> = []
            for w in onscreenWindows() {
                guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, managed.contains(pid),
                      let layer = w[kCGWindowLayer as String] as? Int, layer < 1000 else { continue }
                if screens.contains(where: { $0.intersects(cgBounds(w)) }) { offenders.insert(pid) }
            }
            for pid in offenders where registry.contains(where: { $0.pid == pid && $0.matchesProcess }) {
                let n = adoptWindows(pid: pid, display: b, slotBase: Int(pid % 5))
                if n > 0 { log("moved \(n) window(s) of pid \(pid) to agent display") }
            }
        } else if managed.isEmpty && !registryUnreadable && now - idleSince > idleTimeout {
            shutdown(reason: "idle for \(Int(idleTimeout))s with no managed apps")
        }

        // 2. Keep the user's cursor off the agent display.
        if let loc = CGEvent(source: nil)?.location, b.contains(loc) {
            let points = screens.map { u in
                CGPoint(x: min(max(loc.x, u.minX), u.maxX - 1), y: min(max(loc.y, u.minY), u.maxY - 1))
            }
            guard let p = points.min(by: { hypot($0.x-loc.x, $0.y-loc.y) < hypot($1.x-loc.x, $1.y-loc.y) }) else { return }
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func shutdown(reason: String) {
        guard !stopping else { return }
        // A launch holds lifecycle.lock (shared) until its app is registered; never tear down under one.
        guard let lifecycle = try? StateLock("lifecycle.lock", nonblocking: true) else { pendingShutdown = reason; return }
        defer { withExtendedLifetime(lifecycle) {} }
        pendingShutdown = nil
        let records: [ManagedApp]
        do {
            records = try AppStore.read(allowMissing: !registryUnreadable && !registry.contains { $0.matchesProcess })
        } catch {
            registryUnreadable = true
            log("retaining display because the app registry could not be read: \(error)")
            return
        }
        if reason.hasPrefix("idle "), !records.isEmpty {
            idleSince = ProcessInfo.processInfo.systemUptime
            return
        }
        stopping = true
        log("shutting down: \(reason)")
        for record in records {
            do { try record.requestTermination(force: false) } catch { log("quit pid \(record.pid): \(error)") }
        }
        _ = waitFor(timeout: 3) { records.contains { $0.matchesProcess } ? nil : true }
        for record in records where record.matchesProcess {
            do { try record.requestTermination(force: true) } catch { log("force quit pid \(record.pid): \(error)") }
        }
        _ = waitFor(timeout: 1) { records.contains { $0.matchesProcess } ? nil : true }
        do {
            guard !records.contains(where: { $0.matchesProcess }) else {
                throw CLIError("managed processes are still running")
            }
            try AppStore.update { remaining in
                guard remaining.isEmpty else { throw CLIError("live registrations remain") }
            }
        } catch {
            stopping = false
            idleSince = ProcessInfo.processInfo.systemUptime
            log("retaining display: \(error)")
            return
        }
        try? FileManager.default.removeItem(at: Paths.daemon)
        log("bye")
        exit(0)
    }
}

/// Start the daemon in the background (new session, survives the terminal) if not running.
@discardableResult
func ensureDaemon() throws -> DaemonInfo {
    let (info, lifecycle) = try beginLaunch()
    lifecycle.release()
    return info
}

/// Start the daemon if needed and return it with lifecycle.lock held shared. A launch keeps the
/// lock until its app is registered, so the daemon can't shut down around an app it can't see
/// yet. Shared, so launches in different sessions don't wait for each other.
func beginLaunch() throws -> (info: DaemonInfo, lifecycle: StateLock) {
    let client = try StateLock("client.lock")
    defer { client.release() }
    let lifecycle = try StateLock("lifecycle.lock", shared: true)
    return (try startDaemon(), lifecycle)
}

private func startDaemon() throws -> DaemonInfo {
    if let d = liveDaemon() { return d }
    try Paths.ensure()
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let selfPath = FileManager.default.fileExists(atPath: exe) ? exe : (Bundle.main.executablePath ?? exe)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, Paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_addopen(&fa, 2, Paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(selfPath), strdup("__daemon"), nil]
    defer { for pointer in argv { free(pointer) } }
    let rc = posix_spawn(&pid, selfPath, &fa, &attr, argv, environ)
    posix_spawn_file_actions_destroy(&fa)
    posix_spawnattr_destroy(&attr)
    guard rc == 0 else { throw CLIError("failed to spawn daemon: \(String(cString: strerror(rc)))") }
    var status: Int32 = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    repeat {
        if let info = liveDaemon() { return info }
        if waitpid(pid, &status, WNOHANG) == pid {
            throw CLIError("daemon exited during startup; see \(Paths.log.path)")
        }
        pump(0.1)
    } while ProcessInfo.processInfo.systemUptime < deadline
    // An unreaped child still owns its PID, so this cannot signal a replacement process.
    if waitpid(pid, &status, WNOHANG) == 0 {
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    throw CLIError("daemon did not come up; see \(Paths.log.path)")
}

/// Quit apps gracefully, then forcefully. True once all of them are gone.
@discardableResult
func quitApps(_ records: [ManagedApp]) -> Bool {
    for record in records { try? record.requestTermination(force: false) }
    _ = waitFor(timeout: 3) { records.contains { $0.matchesProcess } ? nil : true }
    for record in records where record.matchesProcess { try? record.requestTermination(force: true) }
    return waitFor(timeout: 2) { records.contains { $0.matchesProcess } ? nil : true } != nil
}

/// `stop`: quit the calling session's apps. Then, if no session has apps left, stop the daemon
/// too, as a single agent would expect. Other sessions' and legacy apps are never touched.
func stopSession() throws -> [String: Any] {
    let session = try Session.current()
    var quit: [Int32] = []
    var allGone = true
    do {
        let lock = try Locks.session(session.id)
        defer { lock.release() }
        // A launch in this session that started before now gives up instead of registering.
        lock.stamp = Date().timeIntervalSince1970
        let mine = try AppStore.read().filter { $0.session == session.id }
        quit = mine.map { $0.pid }
        allGone = quitApps(mine)
        try AppStore.update { _ in }   // prune by process identity
    }
    Locks.pruneAppLocks()
    var result: [String: Any] = ["ok": allGone, "session": session.id, "quit": quit]
    if !allGone { result["error"] = "some of this session's apps did not quit" }
    result["daemon"] = try stopDaemonIfIdle()
    return result
}

private func stopDaemonIfIdle() throws -> String {
    let client = try StateLock("client.lock")
    defer { client.release() }
    let daemon: DaemonInfo
    do {
        // Exclusive: wait out launches that haven't registered their app yet. New launches
        // can't start while client.lock is held, so the emptiness check stays true.
        let lifecycle = try StateLock("lifecycle.lock")
        defer { lifecycle.release() }
        let remaining = try AppStore.read()
        if !remaining.isEmpty {
            return "running (\(remaining.count) app\(remaining.count == 1 ? "" : "s") in other sessions)"
        }
        guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else { return "not running" }
        guard kill(d.pid, SIGTERM) == 0 || errno == ESRCH else { throw CLIError("failed to signal daemon") }
        daemon = d
    }
    guard waitFor(timeout: 8, { daemon.matchesProcess ? nil : true }) != nil else {
        throw CLIError("daemon did not stop within 8 seconds; see \(Paths.log.path)")
    }
    return "stopped"
}

/// `stop --all`: the admin form. Quit every managed app in every session (legacy included) and
/// stop the daemon.
func stopAll() throws -> [String: Any] {
    let client = try StateLock("client.lock")
    defer { client.release() }
    var daemon: DaemonInfo?
    var quit: [Int32] = []
    do {
        let lifecycle = try StateLock("lifecycle.lock")
        defer { lifecycle.release() }
        if let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess {
            // The daemon quits every app before it removes the display.
            guard kill(d.pid, SIGTERM) == 0 || errno == ESRCH else { throw CLIError("failed to signal daemon") }
            daemon = d
        } else {
            let records = try AppStore.read()
            quit = records.map { $0.pid }
            guard quitApps(records) else { throw CLIError("some managed apps did not quit") }
            try AppStore.update { _ in }
        }
    }
    if let daemon {
        guard waitFor(timeout: 8, { daemon.matchesProcess ? nil : true }) != nil else {
            throw CLIError("daemon did not stop within 8 seconds; see \(Paths.log.path)")
        }
    }
    Locks.pruneAppLocks()
    if daemon != nil { return ["ok": true] }
    return quit.isEmpty ? ["ok": true, "note": "daemon not running"] : ["ok": true, "quit": quit]
}
