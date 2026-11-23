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
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            autoreleasepool { self?.tick() }
        }
        RunLoop.main.run()
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
        guard let session = try? StateLock("session.lock", nonblocking: true) else { pendingShutdown = reason; return }
        defer { withExtendedLifetime(session) {} }
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
    try withLaunchSession { $0 }
}

func withLaunchSession<T>(_ body: (DaemonInfo) throws -> T) throws -> T {
    try withExtendedLifetime(try StateLock("client.lock")) {
        try withExtendedLifetime(try StateLock("session.lock")) { try body(startDaemon()) }
    }
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

func stopDaemon() throws -> [String: Any] {
    let client = try StateLock("client.lock")
    defer { withExtendedLifetime(client) {} }
    let daemon: DaemonInfo? = try withExtendedLifetime(try StateLock("session.lock")) {
        guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else { return nil }
        guard kill(d.pid, SIGTERM) == 0 || errno == ESRCH else { throw CLIError("failed to signal daemon") }
        return d
    }
    guard let daemon else { return ["ok": true, "note": "daemon not running"] }
    guard waitFor(timeout: 8, { daemon.matchesProcess ? nil : true }) != nil else {
        throw CLIError("daemon did not stop within 8 seconds; see \(Paths.log.path)")
    }
    return ["ok": true]
}
