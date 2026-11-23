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

/// Place a window in the first free spot on the agent display, so windows of different apps
/// (and sessions) don't overlap; cascade if nothing fits. `avoiding` adds rects that aren't on
/// screen yet, such as windows of the same hidden app placed just before. Returns the frame.
/// Two launches placing at the same moment can still pick the same spot (each other's windows
/// are hidden); that overlap is harmless for capture and input.
@discardableResult
func placeBeside(_ w: AXUIElement, display b: CGRect, avoiding: [CGRect] = []) -> CGRect {
    let me = w.windowID
    let occupied = onscreenWindows()
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowNumber as String] as? CGWindowID) != me }
        .map(cgBounds)
        // Only windows mostly on the agent display count: not ones that just overlap its edge.
        .filter { $0.width > 50 && $0.height > 50 && b.intersection($0).width * b.intersection($0).height >= $0.width * $0.height / 2 }
        .map { b.intersection($0) } + avoiding
    let size = w.size ?? CGSize(width: 400, height: 300)
    if let spot = freeSpot(size, occupied: occupied, display: b) {
        w.setPosition(spot)
        return CGRect(origin: spot, size: size)
    }
    placeOnAgentDisplay(w, display: b, slot: occupied.count)
    return w.frame ?? CGRect(origin: b.origin, size: size)
}

/// First-fit: rows top to bottom, then left to right, with candidate edges taken from the
/// windows already there. Nil when the display is full.
func freeSpot(_ size: CGSize, occupied: [CGRect], display b: CGRect) -> CGPoint? {
    let gap: CGFloat = 20, left = b.minX + 40, top = b.minY + 60
    let xs = Set([left] + occupied.map { $0.maxX + gap }).filter { $0 >= left && $0 + size.width <= b.maxX - 10 }.sorted()
    let ys = Set([top] + occupied.map { $0.maxY + gap }).filter { $0 >= top && $0 + size.height <= b.maxY - 10 }.sorted()
    for y in ys {
        for x in xs {
            let spot = CGRect(x: x, y: y, width: size.width, height: size.height).insetBy(dx: -gap / 2, dy: -gap / 2)
            if !occupied.contains(where: { $0.intersects(spot) }) { return CGPoint(x: x, y: y) }
        }
    }
    return nil
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
    /// Per-app audio levels for the menu bar meter (set by the tap manager; read by StatusMenu).
    var audioLevels: AudioLevelSource?
    var nextMenuUpdate = 0.0
    let sizeSource: String
    let inputGuard = InputGuard()
    var inputGuardUp = false

    init() throws {
        owner = try StateLock("daemon.lock", nonblocking: true)
        let env = ProcessInfo.processInfo.environment
        // By default the agent display has the main display's size in points, so screenshots have
        // the user's aspect ratio. It's read once, here: if the user's displays change later
        // (another monitor, a new resolution), the live display keeps its size until a restart.
        let main = mainDisplaySize()
        func points(_ v: CGFloat?, _ fallback: Int) -> String { String(v.map { Int($0.rounded()) } ?? fallback) }
        guard let w = UInt32(env["BACKSTAGE_WIDTH"] ?? points(main?.width, 1920)), w > 0,
              let h = UInt32(env["BACKSTAGE_HEIGHT"] ?? points(main?.height, 1200)), h > 0 else {
            throw CLIError("BACKSTAGE_WIDTH and BACKSTAGE_HEIGHT must be positive integers")
        }
        sizeSource = env["BACKSTAGE_WIDTH"] != nil || env["BACKSTAGE_HEIGHT"] != nil ? "env" : main != nil ? "main display" : "default"
        // Retina (2x) by default: same size in points, twice the pixels. BACKSTAGE_SCALE=1 opts out.
        guard let scale = UInt32(env["BACKSTAGE_SCALE"] ?? "2"), scale == 1 || scale == 2 else {
            throw CLIError("BACKSTAGE_SCALE must be 1 or 2")
        }
        guard w <= 8192, h <= 8192 else { throw CLIError("BACKSTAGE_WIDTH and BACKSTAGE_HEIGHT must be at most 8192 points") }
        guard let timeout = Double(env["BACKSTAGE_IDLE_TIMEOUT"] ?? "1800"),
              timeout.isFinite, timeout >= 0, timeout < Double(Int.max) else {
            throw CLIError("BACKSTAGE_IDLE_TIMEOUT must be a finite nonnegative number of seconds")
        }
        idleTimeout = timeout
        display = try AgentDisplay(width: w, height: h, scale: scale)
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: Paths.log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: Paths.log, atomically: true, encoding: .utf8) }
    }

    func run() throws -> Never {
        // Wait for the display to come online, give it its mode (Retina or 1x), then park it.
        guard waitFor(timeout: 5, { activeDisplays().contains(display.id) ? true : nil }) != nil else {
            throw CLIError("could not bring the agent display online")
        }
        guard display.selectMode() else {
            throw CLIError("could not set the agent display to \(display.size.width)x\(display.size.height) points at \(display.size.scale)x")
        }
        guard display.park() else { throw CLIError("could not park the agent display") }
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
                self.inputGuard.update(managed: self.managed, userPid: app.processIdentifier)
            }
        }
        // Keep the user's input out of managed apps (an open menu takes the keyboard focus).
        inputGuard.update(managed: managed, userPid: lastUserApp?.processIdentifier ?? 0)
        inputGuardUp = inputGuard.start()
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
        log(inputGuardUp ? "input guard up" : "input guard unavailable (event tap refused; Accessibility not granted?): input commands will refuse to run")
        // Menu bar indicator: the daemon runs as an accessory app (no Dock icon, never activates).
        if ProcessInfo.processInfo.environment["BACKSTAGE_MENUBAR"] != "off" {
            NSApplication.shared.setActivationPolicy(.accessory)
            statusMenu = StatusMenu(daemon: self)
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            autoreleasepool {
                let started = ProcessInfo.processInfo.systemUptime
                self?.tick()
                // While a tick runs, nothing guards windows or the cursor: report long ones.
                let took = ProcessInfo.processInfo.systemUptime - started
                if took > 0.5 { self?.log(String(format: "slow tick: %.2fs", took)) }
            }
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

    /// Set once a shutdown is requested (not for idle ones), and published in daemon.json so a
    /// launch starts a fresh daemon instead of registering an app with this one.
    var shutdownRequested = false

    func writeInfo() throws {
        let b = display.bounds
        try writeJSON(Paths.daemon, DaemonInfo(pid: getpid(), displayID: display.id, x: b.minX, y: b.minY, width: b.width, height: b.height,
                                               startedAt: startedAt, processStart: processBirth(getpid()),
                                               protocol: DaemonInfo.currentProtocol, stopping: shutdownRequested ? true : nil,
                                               sizeSource: sizeSource, inputGuard: inputGuardUp))
    }

    func markShutdown(_ requested: Bool) {
        guard shutdownRequested != requested else { return }
        shutdownRequested = requested
        do { try writeInfo() } catch { log("cannot update display state: \(error)") }
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
        inputGuard.update(managed: managed, userPid: lastUserApp?.processIdentifier ?? 0)
        for pid in managed where observers[pid] == nil && now >= observeAfter[pid, default: 0] { observe(pid, now: now) }
        observeAfter = observeAfter.filter { managed.contains($0.key) }
        for pid in observers.keys where !managed.contains(pid) {
            if let o = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            }
        }
    }

    var observers: [pid_t: AXObserver] = [:]
    var observeAfter: [pid_t: Double] = [:]

    func observe(_ pid: pid_t, now: Double) {
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, _ in
            guard let d = Daemon.shared, !d.stopping else { return }
            d.windowAppeared(element)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let app = axApp(pid)
        // Registration fails while the app is still starting up; retry until it sticks. An app
        // whose main thread is busy (a slow launch) doesn't answer, and this runs on the guard
        // loop: wait briefly, and retry at most once a second, so the loop never stalls.
        AXUIElementSetMessagingTimeout(app, 0.1)
        let rc = AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, nil)
        guard rc == .success || rc == .notificationAlreadyRegistered else { observeAfter[pid] = now + 1; return }
        AXUIElementSetMessagingTimeout(app, 3)
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
    var nextReap = 0.0
    var launchesPending = false
    var orphanSince: [String: Double] = [:]

    func registered(_ pid: pid_t, _ birth: UInt64) -> Bool {
        AppStore.load().contains { $0.pid == pid && $0.processStart == birth }
    }

    /// Once a second: quit apps whose launch died before registering them (see LaunchRecord).
    func reapLaunches(now: Double) {
        guard now >= nextReap else { return }
        nextReap = now + 1
        reapOrphanLaunches(deadSince: &orphanSince, registered: registered, log: log)
        launchesPending = !Launching.records().isEmpty
    }

    var nextGuardLog = 0.0
    func tick() {
        guard !stopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let reason = pendingShutdown { shutdown(reason: reason); return }
        reloadManaged(now: now)
        reapLaunches(now: now)
        if now >= nextGuardLog { nextGuardLog = now + 1; inputGuard.logActivity(log) }
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
        } else if launchesPending {
            idleSince = ProcessInfo.processInfo.systemUptime
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
        let idle = reason.hasPrefix("idle ")
        // From now on, new launches wait for this daemon to exit and start a fresh one.
        if !idle { markShutdown(true) }
        // A launch holds lifecycle.lock (shared) until its app is registered; never tear down
        // under one. Older CLIs (protocol 1) held session.lock for the same purpose.
        guard let lifecycle = try? StateLock("lifecycle.lock", nonblocking: true),
              let legacyLifecycle = try? StateLock("session.lock", nonblocking: true) else { pendingShutdown = reason; return }
        defer { withExtendedLifetime((lifecycle, legacyLifecycle)) {} }
        pendingShutdown = nil
        let records: [ManagedApp]
        do {
            records = try AppStore.read(allowMissing: !registryUnreadable && !registry.contains { $0.matchesProcess })
        } catch {
            registryUnreadable = true
            log("retaining display because the app registry could not be read: \(error)")
            markShutdown(false)
            return
        }
        if idle, !records.isEmpty || !Launching.records().isEmpty {
            idleSince = ProcessInfo.processInfo.systemUptime
            return
        }
        stopping = true
        log("shutting down: \(reason)")
        // No launch can be running (lifecycle.lock is ours), so every provisional record is an
        // orphan: quit what it started before the display goes.
        let orphans = reapOrphanLaunches(deadSince: &orphanSince, registered: { _, _ in false }, final: true, log: log)
        for record in records {
            do { try record.requestTermination(force: false) } catch { log("quit pid \(record.pid): \(error)") }
        }
        _ = waitFor(timeout: 2) { orphans.contains { processAlive($0) } ? nil : true }
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
            markShutdown(false)
            return
        }
        try? FileManager.default.removeItem(at: Paths.daemon)
        inputGuard.logActivity(log, force: true)
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
    for _ in 0..<3 {
        // A daemon on its way out needs lifecycle.lock exclusively, so wait for it unlocked.
        try settleDaemon()
        let lifecycle = try StateLock("lifecycle.lock", shared: true)
        // Asked to stop after settleDaemon looked (its shutdown waits on another launch): retry.
        if let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess, d.stopping == true || d.protocolMismatch {
            lifecycle.release()
            continue
        }
        return (try startDaemon(), lifecycle)
    }
    throw CLIError("the backstage daemon kept shutting down while this launch waited; try again")
}

/// Commands that need the daemon refuse one from another backstage version: it doesn't know
/// sessions or this version's locks, and its registry writes drop sessions' ownership.
func daemonVersionError(_ d: DaemonInfo) -> CLIError {
    let which = (d.protocol ?? 1) < DaemonInfo.currentProtocol ? "an older" : "a newer"
    return CLIError("the running backstage daemon (pid \(d.pid)) is from \(which) version of backstage; "
        + "run `backstage stop --all` (quits every managed app) to replace it, then retry")
}

/// With client.lock held and lifecycle.lock not: wait for a stopping daemon to exit, and replace
/// an idle daemon from another version (one with apps is refused).
private func settleDaemon() throws {
    guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else { return }
    if d.stopping != true {
        guard d.protocolMismatch else { return }
        guard try AppStore.read().isEmpty, Launching.records().isEmpty else { throw daemonVersionError(d) }
        guard kill(d.pid, SIGTERM) == 0 || errno == ESRCH else { throw CLIError("failed to signal the old daemon (pid \(d.pid))") }
    }
    // Done when it exits, or when it gives up shutting down (an app wouldn't quit) and clears the flag.
    let gone = waitFor(timeout: 30) {
        !d.matchesProcess || (d.stopping == true && readJSON(Paths.daemon, DaemonInfo.self)?.stopping != true) ? true : nil
    }
    guard gone != nil else {
        throw CLIError("the backstage daemon (pid \(d.pid)) is shutting down but hasn't exited after 30s; try again, or see \(Paths.log.path)")
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
    Locks.pruneSessionLocks()
    var result: [String: Any] = ["ok": allGone, "session": session.id, "quit": quit]
    var errors: [String] = []
    if !allGone { errors.append("some of this session's apps did not quit") }
    do {
        result["daemon"] = try stopDaemonIfIdle(session: session.id)
    } catch {
        // Keep the quit list: the apps are gone even if the daemon didn't follow.
        result["daemon"] = "error"
        errors.append("\(error)")
    }
    if !errors.isEmpty {
        result["ok"] = false
        result["error"] = errors.joined(separator: "; ")
    }
    return result
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

private func stopDaemonIfIdle(session: String) throws -> String {
    let client = try StateLock("client.lock")
    defer { client.release() }
    let daemon: DaemonInfo
    do {
        // Exclusive, so no launch is between starting the daemon and registering its app; new
        // launches can't start while client.lock is held, so the emptiness check stays true.
        // Don't wait for it, though: a launch holds it shared through `open` and identifying
        // its app (up to ~15 s), `show` while it hands an app over, and waiting here would keep
        // client.lock, and with it every other session's launch, blocked that long. A daemon
        // left running stops itself after its idle timeout.
        let lifecycle: StateLock
        do { lifecycle = try StateLock("lifecycle.lock", nonblocking: true) }
        catch where StateLock.isBusy(error) { return "running (a launch or show is in progress in some session)" }
        defer { lifecycle.release() }
        let remaining = try AppStore.read()
        if !remaining.isEmpty {
            let mine = remaining.filter { $0.session == session }.count
            var parts: [String] = []
            if mine > 0 { parts.append("\(plural(mine, "app")) of this session didn't quit") }
            if remaining.count > mine { parts.append("\(plural(remaining.count - mine, "app")) in other sessions") }
            return "running (" + parts.joined(separator: "; ") + ")"
        }
        guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else { return "not running" }
        if !Launching.records().isEmpty { return "running (a launch is being cleaned up)" }
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
    Locks.pruneSessionLocks()
    if daemon != nil { return ["ok": true] }
    return quit.isEmpty ? ["ok": true, "note": "daemon not running"] : ["ok": true, "quit": quit]
}
