import Foundation
import AppKit
import ApplicationServices
import CBackstageAudio

/// Place a window inside the agent display, cascading by `slot`, shrinking it if it doesn't fit.
func placeOnAgentDisplay(_ w: AXUIElement, display b: CGRect, slot: Int, size: CGSize? = nil) {
    let margin: CGFloat = 40, top: CGFloat = 60
    let off = CGFloat(slot % 8) * 30
    let insetX = min(margin, b.width / 10), insetY = min(top, b.height / 10)
    var x = insetX + off, y = insetY + off
    if let s = size ?? w.size {
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
    placeBesideReporting(w, display: b, avoiding: avoiding).frame
}

/// `placeBeside`, also saying whether the display had no free spot (the window cascaded).
func placeBesideReporting(_ w: AXUIElement, display b: CGRect, avoiding: [CGRect] = []) -> (frame: CGRect, cascaded: Bool) {
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
        return (CGRect(origin: spot, size: size), false)
    }
    placeOnAgentDisplay(w, display: b, slot: occupied.count)
    return (w.frame ?? CGRect(origin: b.origin, size: size), !occupied.isEmpty)
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

/// One AX request for the geometry and minimized state needed by the window guard.
private func guardWindowState(_ window: AXUIElement) -> (frame: CGRect, minimized: Bool)? {
    AXUIElementSetMessagingTimeout(window, guardAXTimeout)
    let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute] as CFArray
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
          let values = values as? [AnyObject], values.count == 3 else { return nil }
    if (values[2] as? Bool) == true { return (.null, true) }
    guard CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(values[0] as! AXValue, .cgPoint, &position),
          AXValueGetValue(values[1] as! AXValue, .cgSize, &size) else { return nil }
    return (CGRect(origin: position, size: size), false)
}

private let guardAXTimeout: Float = 0.1

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

private func adoptVisibleWindows(pid: pid_t, display b: CGRect) -> Int {
    var moved = 0
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, guardAXTimeout)
    for (i, w) in app.windows.enumerated() {
        guard let state = guardWindowState(w), !state.minimized, !b.contains(state.frame) else { continue }
        placeOnAgentDisplay(w, display: b, slot: Int(pid % 5) + i, size: state.frame.size)
        moved += 1
    }
    return moved
}

/// A duration from the environment: finite, at least 0, at most a day (tests shorten them).
private func boundedSeconds(_ key: String, default value: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[key], let v = Double(raw), v.isFinite, v >= 0, v <= 86_400 else { return value }
    return v
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
    /// The audio tap manager (AudioTaps.swift; macOS 14.2+), and why muting is unavailable if it isn't.
    var audioTaps: AudioTapControl?
    var audioUnavailable: String? = "audio muting needs macOS 14.2 or later"
    var audioRegistry: [AudioRegistryEntry] = []
    var nextMenuUpdate = 0.0
    let sizeSource: String
    let inputGuard = InputGuard()
    var inputGuardUp = false
    /// The user's app switches, most recent first (Send Front Window Backstage hands focus back).
    var recentUserApps: [NSRunningApplication] = []
    var sendInFlight = false
    /// settings.json as last applied, and its stamp (published in daemon.json).
    var settings = Settings()
    var settingsApplied: String?
    var nextSettingsCheck = 0.0
    var hotKey: GlobalHotKey?
    /// The hotkey settings asked for when last applied, and why it couldn't be registered.
    var hotkeyWanted: String??
    var hotkeyError: String?
    /// Keep in Menu Bar is on and there is a menu bar item to keep: no idle exit.
    var keepActive: Bool { settings.keep && statusMenu != nil }
    let testSendRequests = ProcessInfo.processInfo.environment["BACKSTAGE_TEST_SEND_REQUESTS"] == "1"

    // MARK: extra displays (docs/MULTI_DISPLAY_PLAN.md, phase 2)
    /// Displays beyond the primary, by slot, with when each was created.
    var extras: [Int: AgentDisplay] = [:]
    var extraCreated: [Int: Double] = [:]
    /// `launch --display new`: the session a display is reserved for, until when (epoch seconds).
    var reservations: [Int: (session: String, until: Double)] = [:]
    /// The size every display gets (the primary's).
    var displaySize: (width: UInt32, height: UInt32, scale: UInt32) { display.size }
    /// Slots extra displays may take: 2-6, or BACKSTAGE_EXTRA_DISPLAYS (tests: "8").
    let extraSlots: [Int] = {
        if let raw = ProcessInfo.processInfo.environment["BACKSTAGE_EXTRA_DISPLAYS"] {
            return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { displaySlots.contains($0) }
        }
        return Array(sharedDisplaySlots)
    }()
    /// How long a reservation lasts, and how long an empty extra display waits before it goes
    /// (a launch may be about to put its app there). Shortened by tests.
    let reservationSeconds = boundedSeconds("BACKSTAGE_RESERVATION_SECONDS", default: 1800)
    let extraGraceSeconds = boundedSeconds("BACKSTAGE_EXTRA_DISPLAY_GRACE", default: 30)
    var creatingDisplay = false
    var nextExtrasCheck = 0.0
    var nextRemovalCheck = 0.0
    private var displayStateDirty = false
    private var requestDirectoryVersion: FileVersion?
    private var nextRequestRescan = 0.0
    private var nextReplyExpiry = Double.infinity

    /// Every display this daemon runs, the primary first.
    var allDisplays: [AgentDisplay] { [display] + extras.keys.sorted().compactMap { extras[$0] } }
    var ownDisplayIDs: Set<CGDirectDisplayID> { Set(allDisplays.map { $0.id }) }
    /// The display a managed app's windows belong on.
    func displayFor(pid: pid_t) -> AgentDisplay {
        guard let slot = registry.first(where: { $0.pid == pid })?.display, let d = extras[slot] else { return display }
        return d
    }

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

    private let logLock = NSLock()
    private let logDateFormatter = ISO8601DateFormatter()

    func log(_ s: String) {
        logLock.lock()
        defer { logLock.unlock() }
        appendLogLine("\(logDateFormatter.string(from: Date())) \(s)\n", to: Paths.log)
    }

    func run() throws -> Never {
        // Wait for the display to come online, park it at once (macOS first puts a new display
        // edge to edge with the user's), give it its mode (Retina or 1x), and check it's parked.
        guard waitFor(timeout: 5, { activeDisplays().contains(display.id) ? true : nil }) != nil else {
            throw CLIError("could not bring the agent display online")
        }
        guard display.park(force: true) else { throw CLIError("could not park the agent display") }
        guard display.selectMode() else {
            throw CLIError("could not set the agent display to \(display.size.width)x\(display.size.height) points at \(display.size.scale)x")
        }
        guard display.park() else { throw CLIError("could not park the agent display") }
        pump(0.5)
        refreshScreens()

        lastUserApp = NSWorkspace.shared.frontmostApplication
        if let front = lastUserApp { noteUserApp(front) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if self.managed.contains(app.processIdentifier) {
                self.restoreUserFocus(after: app)
            } else {
                self.lastUserApp = app
                self.inputGuard.updateUser(app.processIdentifier)
                if app.processIdentifier != getpid() { self.noteUserApp(app) }
            }
        }
        // Keep the user's input out of managed apps (an open menu takes the keyboard focus).
        inputGuard.updateUser(lastUserApp?.processIdentifier ?? 0)
        inputGuardUp = inputGuard.start()
        // Monitor arrangement changes (user plugs in a screen, another home's daemon adds its
        // display): guard the new layout at once, re-park if needed.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async { Daemon.shared?.refreshScreens(); Daemon.shared?.scheduleRepark() }
        }, nil)

        // A crash kills the managed apps first (C handler, fixed PID table): otherwise their
        // windows land on the user's screen and their audio comes out unmuted.
        bs_crash_install()
        startAudio()

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.shutdown(reason: "signal \(sig)") }
            s.resume()
            signalSources.append(s)
        }

        try writeInfo()
        log("daemon up pid=\(getpid()) display=\(display.id) serial=\(display.serial) bounds=\(display.bounds)")
        log(inputGuardUp ? "input guard up" : "input guard unavailable (event tap refused; Accessibility not granted?): input commands will refuse to run")
        // Menu bar indicator: the daemon runs as an accessory app (no Dock icon, never activates).
        if ProcessInfo.processInfo.environment["BACKSTAGE_MENUBAR"] != "off" {
            NSApplication.shared.setActivationPolicy(.accessory)
            statusMenu = StatusMenu(daemon: self)
        }
        applySettings()
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

    private func restoreUserFocus(after app: NSRunningApplication) {
        guard app.isActive, let back = lastUserApp, !back.isTerminated,
              back.processIdentifier != getpid(), !managed.contains(back.processIdentifier),
              let birth = processBirth(back.processIdentifier),
              let managedBirth = processBirth(app.processIdentifier) else { return }
        back.activate()
        log("managed app \(app.processIdentifier) took focus; handing focus back to \(back.bundleIdentifier ?? "?")")
        // Cooperative activation can be refused. Retry once through AX only if the same
        // managed app still has focus and the user hasn't switched apps in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, !self.stopping, self.lastUserApp === back,
                  self.managed.contains(app.processIdentifier), !self.managed.contains(back.processIdentifier),
                  app.isActive, processBirth(app.processIdentifier) == managedBirth,
                  !back.isTerminated, processBirth(back.processIdentifier) == birth else { return }
            let target = AXUIElementCreateApplication(back.processIdentifier)
            AXUIElementSetMessagingTimeout(target, guardAXTimeout)
            AXUIElementSetAttributeValue(target, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    static var shared: Daemon?

    /// The user's displays, and every backstage display but ours (other homes' daemons).
    var otherAgentScreens: [CGRect] = []
    @discardableResult
    func refreshScreens(from geometry: DisplayGeometry = DisplayGeometry()) -> (users: [CGRect], agents: [CGDirectDisplayID: CGRect]) {
        let classified = geometry.classified()
        screens = classified.users
        let own = ownDisplayIDs
        otherAgentScreens = classified.agents.compactMap { own.contains($0.key) ? nil : $0.value }
        return classified
    }

    var reparkPending = false
    var reparkFailures = 0
    func scheduleRepark() {
        guard !reparkPending else { return }
        reparkPending = true
        // Staggered by serial, so daemons reacting to the same change don't all move at once
        // (park() also serializes them, and a parked display never moves).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(display.serial % 8) * 0.05) {
            self.reparkPending = false
            self.repark()
        }
    }
    func repark() {
        guard !stopping else { return }
        if creatingDisplay { scheduleRepark(); return }
        // Monitor unplugged / turned off: the agent display would become the user's only screen
        // and their windows would migrate onto it. Bail out so it disappears.
        var geometry = refreshScreens()
        if screens.isEmpty { shutdown(reason: "no user display left"); return }
        var failed = false
        for d in allDisplays where !d.isParked(users: geometry.users, agents: geometry.agents) {
            let was = d.bounds
            if d.park() {
                if d.bounds != was { log("re-parked display \(d.slot) from \(was) to \(d.bounds)") }
            } else {
                failed = true
                log("could not re-park display \(d.slot) (at \(d.bounds)); retrying")
            }
            geometry = refreshScreens()
        }
        if failed {
            // Another (older) daemon may be moving its display right now: try again shortly,
            // but don't stay touching the user's desktop along an edge.
            reparkFailures += 1
            guard reparkFailures < 4 else { shutdown(reason: "failed to re-park display"); return }
            scheduleRepark()
        } else {
            reparkFailures = 0
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
                                               sizeSource: sizeSource, inputGuard: inputGuardUp,
                                               audio: audioUnavailable == nil, audioReason: audioUnavailable,
                                               audioModes: true, delayedLaunchHandoff: true,
                                               hotkey: hotKey?.registered?.spec, hotkeyError: hotkeyError, settingsApplied: settingsApplied,
                                               displays: displayEntries()))
    }

    /// Answer `launch --display` / `move --display` requests (files in requests/), expire
    /// reservations, and remove extra displays nothing uses any more.
    func handleDisplayRequests(now: Double) {
        guard !creatingDisplay else { return }
        let wall = Date().timeIntervalSince1970
        var changed = false
        var answerToPublish: (url: URL, reply: DisplayReply)?
        for (slot, r) in reservations where r.until <= wall {
            reservations[slot] = nil
            log("display \(slot): reservation for session \(r.session) expired")
            changed = true
        }
        if let names = displayRequestNames(now: now, wall: wall) {
            for name in names.sorted() {
                let url = Paths.requests.appendingPathComponent(name)
                // Only <uuid>.json requests and <uuid>.reply answers belong here; the reply's name
                // comes from the request's file name, never from its contents.
                let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2, let uuid = UUID(uuidString: parts[0]), uuid.uuidString == parts[0],
                      parts[1] == "json" || parts[1] == "reply" else { continue }
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else {
                    if errno != ENOENT { requestDirectoryVersion = nil }
                    continue
                }
                guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
                if parts[1] == "reply" {
                    // A CLI that gave up leaves its answer: drop it after a minute.
                    let expiresAt = Double(metadata.st_mtimespec.tv_sec)
                        + Double(metadata.st_mtimespec.tv_nsec) / 1e9 + 60
                    if wall >= expiresAt {
                        if unlink(url.path) != 0, errno != ENOENT { requestDirectoryVersion = nil }
                    } else {
                        nextReplyExpiry = min(nextReplyExpiry, expiresAt)
                    }
                    continue
                }
                let decoded = readJSON(url, DisplayRequest.self)
                guard unlink(url.path) == 0 else {
                    if errno != ENOENT { requestDirectoryVersion = nil }
                    continue
                }
                let received = Date().timeIntervalSince1970
                guard let request = decoded, abs(received - request.at) < 30 else { continue }
                let reply = answer(request, wall: received)
                answerToPublish = (Paths.requests.appendingPathComponent("\(parts[0]).reply"), reply)
                changed = changed || reply.ok
                // Display creation can block for seconds. Return to the window guard between requests.
                requestDirectoryVersion = nil
                break
            }
        }
        if !extras.isEmpty, now >= nextRemovalCheck {
            nextRemovalCheck = now + 1
            let pending = Launching.records()
            // Read pending first: a launch may have just moved from pending to registered.
            if let apps = try? AppStore.read(allowMissing: !registryUnreadable && registry.isEmpty) {
                for slot in extras.keys.sorted() {
                    guard answerToPublish?.reply.slot != slot,
                          !apps.contains(where: { $0.display == slot }),
                          !pending.contains(where: { $0.display == slot }),
                          now - (extraCreated[slot] ?? now) >= extraGraceSeconds else { continue }
                    extras[slot] = nil
                    extraCreated[slot] = nil
                    reservations[slot] = nil
                    log("display \(slot) removed: no apps left on it")
                    changed = true
                }
            }
        }
        if changed { refreshScreens(); displayStateDirty = true }
        if displayStateDirty {
            do {
                try writeInfo()
                displayStateDirty = false
            } catch {
                if changed { log("cannot update display state: \(error)") }
            }
        }
        if let (url, reply) = answerToPublish {
            let result = reply.ok && displayStateDirty
                ? DisplayReply(ok: false, slot: nil, error: "could not publish display state") : reply
            do { try writeJSON(url, result) }
            catch { log("cannot answer display request \(url.lastPathComponent): \(error)") }
        }
    }

    private func displayRequestNames(now: Double, wall: Double) -> [String]? {
        let path = Paths.requests.path
        let version = FileVersion(path)
        // Atomic request publication changes the directory. Rescan periodically too, in case
        // the filesystem coalesced timestamps or an entry was modified in place.
        guard version == nil || version != requestDirectoryVersion || now >= nextRequestRescan
                || wall >= nextReplyExpiry else { return nil }
        requestDirectoryVersion = nil
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        requestDirectoryVersion = version   // sampled before listing, so a concurrent write triggers another scan
        nextRequestRescan = now + 5
        nextReplyExpiry = .infinity
        return names
    }

    func answer(_ request: DisplayRequest, wall: Double) -> DisplayReply {
        func refuse(_ why: String) -> DisplayReply { DisplayReply(ok: false, slot: nil, error: why) }
        if request.want == "new" {
            let free = extraSlots.filter { extras[$0] == nil }
            guard !free.isEmpty else { return refuse("no free display left: this daemon runs \(allDisplays.count) (\(allDisplays.map { String($0.slot) }.joined(separator: ", ")))") }
            do {
                let d = try makeExtraDisplay(.lowestFree(free))
                reservations[d.slot] = (request.session, Date().timeIntervalSince1970 + reservationSeconds)
                log("display \(d.slot) reserved for session \(request.session) for \(Int(reservationSeconds))s")
                return DisplayReply(ok: true, slot: d.slot, error: nil)
            } catch { return refuse("\(error)") }
        }
        guard let n = Int(request.want), displaySlots.contains(n) else { return refuse("--display takes a display number (1-8) or new") }
        if n == display.slot { return DisplayReply(ok: true, slot: n, error: nil) }
        if extras[n] != nil {
            if let r = reservations[n], r.until > wall, !Session.sameID(r.session, request.session) {
                let until = DateFormatter.localizedString(from: Date(timeIntervalSince1970: r.until), dateStyle: .none, timeStyle: .short)
                return refuse("display \(n) is reserved for another session until \(until)")
            }
            // A grant is a lease: the display stays at least the grace period from now, while
            // the caller writes its launch record or moves its app.
            extraCreated[n] = ProcessInfo.processInfo.systemUptime
            return DisplayReply(ok: true, slot: n, error: nil)
        }
        guard extraSlots.contains(n) else {
            return refuse("display \(n) isn't one this daemon runs (it runs \(display.slot), and can add \(extraSlots.map(String.init).joined(separator: ", ")))")
        }
        do { return DisplayReply(ok: true, slot: try makeExtraDisplay(.exactly(n)).slot, error: nil) }
        catch { return refuse("\(error)") }
    }

    /// Create, park and size an extra display, like the primary at startup.
    func makeExtraDisplay(_ choice: AgentDisplay.SlotChoice) throws -> AgentDisplay {
        creatingDisplay = true
        defer { creatingDisplay = false }
        let size = displaySize
        let d = try AgentDisplay(width: size.width, height: size.height, scale: size.scale, choice: choice)
        guard waitFor(timeout: 5, { activeDisplays().contains(d.id) ? true : nil }) != nil, d.park(force: true) else {
            throw CLIError("could not bring display \(d.slot) online")
        }
        guard d.selectMode() else { throw CLIError("could not set display \(d.slot) to \(size.width)x\(size.height) points at \(size.scale)x") }
        guard d.park() else { throw CLIError("could not park display \(d.slot)") }
        extras[d.slot] = d
        extraCreated[d.slot] = ProcessInfo.processInfo.systemUptime
        log("display \(d.slot) up at \(d.bounds)")
        return d
    }

    func displayEntries() -> [DisplayEntry] {
        allDisplays.map { d in
            let b = d.bounds
            let r = reservations[d.slot]
            return DisplayEntry(slot: d.slot, displayID: d.id, x: b.minX, y: b.minY, width: b.width, height: b.height,
                                reservedBy: r?.session, reservedUntil: r?.until)
        }
    }

    func markShutdown(_ requested: Bool) {
        guard shutdownRequested != requested else { return }
        shutdownRequested = requested
        do { try writeInfo() } catch { log("cannot update display state: \(error)") }
    }

    /// Read settings.json and apply what changed: Keep in Menu Bar, and the hotkey (re-registered
    /// without a restart). Publishes the result in daemon.json.
    func applySettings() {
        let stamp = settingsStamp()
        let updated = Settings.load()
        // A concurrent CLI write may replace the file between the stamp and the read.
        // Leave the previous result published so the next poll can try again.
        guard settingsStamp() == stamp else { return }
        let old = settings
        settings = updated
        let first = settingsApplied == nil
        settingsApplied = stamp
        if first || old.keep != settings.keep {
            log("keep in menu bar: \(settings.keep ? "on" : "off")" + (settings.keep && statusMenu == nil ? " (ignored: BACKSTAGE_MENUBAR=off)" : ""))
            if !settings.keep { idleSince = ProcessInfo.processInfo.systemUptime }
        }
        let want = settings.effectiveHotKey
        if hotkeyWanted == nil || hotkeyWanted! != want {
            hotkeyWanted = .some(want)
            hotkeyError = nil
            if let spec = want {
                if statusMenu == nil {
                    hotkeyError = "the hotkey needs the menu bar (BACKSTAGE_MENUBAR=off)"
                } else if let combo = try? HotKeyCombo(spec) {
                    let key = hotKey ?? GlobalHotKey { [weak self] in self?.sendFrontWindowBackstage(from: "hotkey") }
                    hotKey = key
                    hotkeyError = key.register(combo)
                } else {
                    hotKey?.unregister()
                    hotkeyError = "settings.json has an invalid hotkey '\(spec)'"
                }
                log(hotkeyError.map { "hotkey: not registered: \($0)" }
                    ?? "hotkey: \(hotKey?.registered?.symbols ?? spec) registered for Send Front Window Backstage")
            } else {
                hotKey?.unregister()
                log("hotkey: off")
            }
        }
        do { try writeInfo() } catch { log("cannot update display state: \(error)") }
        statusMenu?.update(apps: managed.count)
    }

    /// The menu's Quit All while Keep in Menu Bar is on: quit every app (agents' gracefully then
    /// forcefully; the user's own apps gracefully, given back if they don't quit), but keep the
    /// daemon and its icon.
    func quitAllApps() {
        let records = registry.filter { $0.matchesProcess }
        log("quitting all \(records.count) app(s) from the menu bar (keep in menu bar is on)")
        for record in records {
            performOnRegistration(record) { [weak self] current in
                try? current.requestTermination(force: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.performOnRegistration(current, movingWindows: Session.isUser(current.session)) { [weak self] remaining in
                        guard let self else { return }
                        if Session.isUser(remaining.session) { releaseToUser(remaining, log: self.log) }
                        else { try? remaining.requestTermination(force: true) }
                    }
                }
            }
        }
    }

    func quitFromMenu(_ record: ManagedApp, force: Bool) {
        performOnRegistration(record) { [weak self] current in
            do { try current.requestTermination(force: force) }
            catch { self?.log("menu \(force ? "force quit" : "quit") failed: \(error)") }
        }
    }

    /// Serialize termination with the registry removal in show. A failed mute can then
    /// trigger termination even during an input command. Window moves still take the app
    /// lock because giving an app back also updates the registry itself.
    private func performOnRegistration(_ record: ManagedApp, movingWindows: Bool = false,
                                       action: @escaping (ManagedApp) -> Void) {
        guard !stopping, record.matchesProcess else { return }
        do {
            let lock = try movingWindows ? Locks.app(record, nonblocking: true) : Locks.registry(nonblocking: true)
            defer { lock.release() }
            let current = try AppStore.read(matching: {
                $0.pid == record.pid && $0.processStart == record.processStart && $0.launchedAt == record.launchedAt
                    && Session.sameID($0.session, record.session)
            }).first
            if let current { action(current) }
        } catch {
            if StateLock.isBusy(error) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.performOnRegistration(record, movingWindows: movingWindows, action: action)
                }
            } else {
                log("couldn't check registration for pid \(record.pid): \(error)")
            }
        }
    }

    private struct FileVersion: Equatable {
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ path: String) {
            var metadata = stat()
            guard stat(path, &metadata) == 0 else { return nil }
            device = metadata.st_dev
            inode = metadata.st_ino
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
            changedSeconds = metadata.st_ctimespec.tv_sec
            changedNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }
    // Each registry update atomically replaces the file. Read and decode it only after replacement.
    private var registryVersion: FileVersion?
    var registryUnreadable = false
    var registry: [ManagedApp] = []
    func reloadManaged(now: Double) {
        let version = FileVersion(Paths.apps.path)
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
        // An app the user just sent backstage was their frontmost app: never hand focus (or
        // redirected keys) back to it.
        if let last = lastUserApp, managed.contains(last.processIdentifier) {
            lastUserApp = nextUserApp(excluding: last.processIdentifier)
            inputGuard.updateUser(lastUserApp?.processIdentifier ?? 0)
        }
        if !registryUnreadable { pushAudioRegistry() }
        var births: [pid_t: UInt64] = [:]
        for app in registry {
            births[app.pid] = app.processStart ?? processBirth(app.pid)
        }
        inputGuard.update(managed: managed, births: births)
        observeAfter = observeAfter.filter { managed.contains($0.key) }
        for pid in observers.keys where !managed.contains(pid) {
            if let o = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
            }
        }
    }

    var observers: [pid_t: AXObserver] = [:]
    var observeAfter: [pid_t: Double] = [:]

    func observe(_ pid: pid_t, now: Double) {
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, notification, _ in
            guard let d = Daemon.shared, !d.stopping else { return }
            d.windowAppeared(element, created: notification as String == kAXWindowCreatedNotification)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else {
            observeAfter[pid] = now + 1
            return
        }
        let app = AXUIElementCreateApplication(pid)
        // Registration fails while the app is still starting up; retry until it sticks. An app
        // whose main thread is busy (a slow launch) doesn't answer, and this runs on the guard
        // loop: wait briefly, and retry at most once a second, so the loop never stalls.
        AXUIElementSetMessagingTimeout(app, guardAXTimeout)
        let rc = AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, nil)
        guard rc == .success || rc == .notificationAlreadyRegistered else { observeAfter[pid] = now + 1; return }
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowMovedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
        log("observing pid \(pid)")
    }

    func windowAppeared(_ element: AXUIElement, created: Bool) {
        let pid = element.pid
        guard managed.contains(pid) else { return }
        if !created { AXUIElementSetMessagingTimeout(element, guardAXTimeout) }
        // The window-created notification names the window. Other notifications can name
        // an element inside it, so resolve their containing window before moving anything.
        let w: AXUIElement
        if created || element.role == kAXWindowRole {
            w = element
        } else {
            guard let win = element.attr(kAXWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() else { return }
            w = win as! AXUIElement
        }
        let b = displayFor(pid: pid).bounds
        guard let state = guardWindowState(w), !state.minimized, !b.contains(state.frame) else { return }
        let inset = CGPoint(x: b.minX + min(40, b.width / 10), y: b.minY + min(60, b.height / 10))
        // Get the window off the user's screen before calculating a tidy spot.
        guard w.setPosition(inset) == .success else { return }
        placeBeside(w, display: b)
        log("observer moved new window of pid \(pid)")
    }

    var nextReload = 0.0
    var pendingShutdown: String?
    var nextReap = 0.0
    var launchesPending = false
    var orphanSince: [String: Double] = [:]

    func registered(_ pid: pid_t, _ birth: UInt64) throws -> Bool {
        let expectRegistry = registry.contains { $0.pid == pid && $0.matchesProcess }
        return try AppStore.read(allowMissing: !expectRegistry, matching: { $0.pid == pid }).contains {
            ($0.processStart ?? $0.liveProcessBirth) == birth
        }
    }

    /// Once a second: quit apps whose launch died before registering them, and register those
    /// whose launch gave up waiting for them (see LaunchRecord).
    func reapLaunches(now: Double) {
        // A missing or invalid registry cannot tell us whether a provisional process was
        // already registered before the CLI died. Leave those records for the next good read.
        guard !registryUnreadable, now >= nextReap else { return }
        nextReap = now + 1
        reapOrphanLaunches(deadSince: &orphanSince, registered: registered,
                           didRegister: { pid, birth in self.toReveal[pid] = (birth, now + 15) }, log: log)
        launchesPending = !Launching.records().isEmpty
        revealRegistered(now: now)
    }

    /// Apps registered here for a launch that gave up on them (still hidden, as LaunchServices
    /// opened them), until their windows are on the agent display: then unhide, as `launch` does.
    var toReveal: [pid_t: (birth: UInt64, until: Double)] = [:]
    func revealRegistered(now: Double) {
        for (pid, entry) in toReveal {
            guard processBirth(pid) == entry.birth else { toReveal[pid] = nil; continue }
            // The per-process lock serializes placement with show and move. Read the
            // record after taking it, since either command may already have changed it.
            guard let lock = try? StateLock("locks/app-\(pid)-\(entry.birth)", nonblocking: true),
                  let records = try? AppStore.read(matching: { $0.pid == pid && $0.processStart == entry.birth }) else {
                if now >= entry.until { toReveal[pid] = nil }
                continue
            }
            defer { lock.release() }
            guard let record = records.first else { toReveal[pid] = nil; continue }
            let slot = record.display
            let b = (slot.flatMap { extras[$0] } ?? display).bounds
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)   // never stall the guard loop on a busy app
            guard let windows = try? app.readElements(kAXWindowsAttribute) else {
                if now >= entry.until { toReveal[pid] = nil; log("pid \(pid): no accessibility answer; left hidden") }
                continue
            }
            var placed = true
            for (i, w) in windows.enumerated() {
                guard let state = guardWindowState(w) else { placed = false; continue }
                if state.minimized || b.contains(state.frame) { continue }
                placeOnAgentDisplay(w, display: b, slot: i, size: state.frame.size)
                if guardWindowState(w).map({ b.contains($0.frame) }) != true { placed = false }
            }
            // A windowless moment right after start: wait for a window (up to 15 s, like --timeout).
            guard placed, !windows.isEmpty || now >= entry.until else {
                if now >= entry.until { toReveal[pid] = nil; log("pid \(pid): windows not on the agent display; left hidden") }
                continue
            }
            toReveal[pid] = nil
            if let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated { _ = running.unhide() }
        }
    }

    var nextGuardLog = 0.0
    private var ticking = false
    func tick() {
        guard !stopping, !ticking else { return }
        ticking = true
        defer { ticking = false }
        let now = ProcessInfo.processInfo.systemUptime
        // The lifecycle lock may still be held by a launch. Keep guarding while we wait.
        if let reason = pendingShutdown { shutdown(reason: reason) }
        reloadManaged(now: now)
        var geometry: DisplayGeometry?
        if now >= nextArrangementCheck {
            nextArrangementCheck = now + 0.25
            let current = DisplayGeometry()
            checkArrangement(current)
            geometry = current
        }
        let own = allDisplays.map { (slot: $0.slot, bounds: geometry?.bounds[$0.id] ?? $0.bounds) }
        let windows = managed.isEmpty ? nil : onscreenWindows()

        // 1. Keep managed windows off the user's screens, and off other homes' backstage
        //    displays (an app restoring a window to where it last was can land there).
        if let windows {
            idleSince = ProcessInfo.processInfo.systemUptime
            // An app's windows belong on its own display: one on a sibling display counts too.
            let slotOf = Dictionary(registry.map { ($0.pid, $0.display ?? display.slot) }, uniquingKeysWith: { a, _ in a })
            var offenders: Set<pid_t> = []
            for w in windows {
                guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, managed.contains(pid),
                      let layer = w[kCGWindowLayer as String] as? Int, layer < 1000 else { continue }
                let f = cgBounds(w)
                let home = slotOf[pid] ?? display.slot
                if screens.contains(where: { $0.intersects(f) }) || otherAgentScreens.contains(where: { $0.intersects(f) })
                    || own.contains(where: { $0.slot != home && $0.bounds.intersects(f) }) {
                    offenders.insert(pid)
                }
            }
            for pid in offenders where registry.contains(where: { $0.pid == pid && $0.matchesProcess }) {
                let d = displayFor(pid: pid)
                let n = adoptVisibleWindows(pid: pid, display: d.bounds)
                if n > 0 { log("moved \(n) window(s) of pid \(pid) to agent display \(d.slot)") }
            }
        }

        // 2. Keep the user's cursor off every backstage display: ours and other homes'.
        //    Points on a user display's bottom or right edge (the Dock) are never on one.
        if let loc = CGEvent(source: nil)?.location, own.contains(where: { $0.bounds.contains(loc) }) || otherAgentScreens.contains(where: { $0.contains(loc) }) {
            let points = screens.map { u in
                CGPoint(x: min(max(loc.x, u.minX), u.maxX - 1), y: min(max(loc.y, u.minY), u.maxY - 1))
            }
            if let p = points.min(by: { hypot($0.x-loc.x, $0.y-loc.y) < hypot($1.x-loc.x, $1.y-loc.y) }) {
                CGWarpMouseCursorPosition(p)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        if now >= nextDockCheck {
            nextDockCheck = now + 1
            guardDock(own: own.map { $0.bounds }, windows: windows, geometry: geometry)
        }
        if now >= nextGuardLog { nextGuardLog = now + 1; inputGuard.logActivity(log) }
        if now >= nextSettingsCheck {
            nextSettingsCheck = now + 0.5
            if settingsStamp() != settingsApplied { applySettings() }
            if testSendRequests { checkTestSendRequest() }
        }
        // Keep in Menu Bar: never idle. Turning it off starts the idle timeout from then.
        if keepActive { idleSince = now }
        if let m = statusMenu, now >= nextMenuUpdate {
            nextMenuUpdate = now + 0.5
            m.update(apps: managed.count)
        }

        // Accessibility registration and deferred launch recovery can block on another app.
        // Do them after moving visible offenders, and attempt at most one registration per tick.
        if let pid = managed.first(where: { observers[$0] == nil && now >= observeAfter[$0, default: 0] }) {
            observe(pid, now: now)
        }
        reapLaunches(now: now)
        if now >= nextExtrasCheck { nextExtrasCheck = now + 0.1; handleDisplayRequests(now: now) }
        if launchesPending { idleSince = ProcessInfo.processInfo.systemUptime }
        if managed.isEmpty && !launchesPending && pendingShutdown == nil && !registryUnreadable && now - idleSince > idleTimeout {
            shutdown(reason: "idle for \(Int(idleTimeout))s with no managed apps")
        }
    }

    /// The reconfiguration callback isn't delivered without an NSApplication (BACKSTAGE_MENUBAR=off),
    /// so watch the arrangement here too.
    var nextArrangementCheck = 0.0
    var arrangement: [CGDirectDisplayID: CGRect] = [:]
    func checkArrangement(_ geometry: DisplayGeometry) {
        guard geometry.bounds != arrangement else { return }
        arrangement = geometry.bounds
        refreshScreens(from: geometry)
        scheduleRepark()
    }

    var nextDockCheck = 0.0
    var dockAway: CGRect?
    /// The Dock must stay on the user's screens. Parking (corner contact only) keeps macOS from
    /// moving it to a backstage display; this catches it if that ever happens anyway.
    func guardDock(own: [CGRect], windows: [[String: Any]]?, geometry: DisplayGeometry?) {
        guard let dock = dockWindowBounds(from: windows) else { return }
        let onto = own.first { contact(dock, $0) == .overlap }
        let ours = onto != nil
        let theirs = otherAgentScreens.contains { contact(dock, $0) == .overlap }
        guard ours || theirs else {
            if let away = dockAway { log("the Dock is back on the user's screen (was at \(away))"); dockAway = nil }
            return
        }
        var needsPark = false
        if ours {
            let (users, agents) = (geometry ?? DisplayGeometry()).classified()
            needsPark = allDisplays.contains { !$0.isParked(users: users, agents: agents) }
        }
        if dockAway == nil {
            // macOS moves the Dock to a display arranged right below its own. Re-parking (which
            // runs on any arrangement change) brings it back by itself ~0.1 s after the move.
            log("the Dock moved onto \(ours ? "this daemon's" : "another backstage") display at \(dock)"
                + (ours && !needsPark ? " though parked: not moving it (no undisruptive way known)" : ""))
        }
        if needsPark { scheduleRepark() }
        dockAway = dock
    }

    /// Start the tap manager before daemon.json exists, so no launch can see a daemon whose
    /// muting isn't up yet. A failed mute self-test leaves `audio: false`: `launch` refuses.
    func startAudio() {
        guard #available(macOS 14.2, *) else { log("audio: macOS 14.2 or later is needed for muting; launch will refuse"); return }
        let taps = AudioTapManager(log: { [weak self] in self?.log($0) }, quit: { pid, birth, registered in
            DispatchQueue.main.async { Daemon.shared?.quitOverAudio(pid: pid, birth: birth, registered: registered) }
        })
        if let failure = taps.start() {
            audioUnavailable = failure
            log("audio: muting unavailable: \(failure); launch will refuse")
            return
        }
        audioUnavailable = nil
        audioTaps = taps
        audioLevels = taps
        log("audio: tap manager up")
    }

    /// Hand the registry to the tap manager when it changes (only after a good read), and keep
    /// the crash handler's PID table current.
    func pushAudioRegistry() {
        let entries = registry.compactMap(AudioRegistryEntry.init)
        guard entries != audioRegistry else { return }
        audioRegistry = entries
        // A crash kills agent apps, never apps the user sent here: those come back to the
        // user's screen with the display's windows.
        let killable = entries.filter { !Session.isUser($0.session) }
        bs_crash_set(0, killable.map { Int32($0.pid) }, killable.map { $0.birth }, Int32(killable.count))
        audioTaps?.updateRegistry(entries)
    }

    /// The tap manager couldn't mute an app: quit it at once, like `stop` (gracefully, then forcefully).
    func quitOverAudio(pid: pid_t, birth: UInt64, registered: Bool) {
        if registered {
            // Use the registration that caused the audio failure. It may have been shown since.
            guard let record = registry.first(where: { $0.pid == pid && ($0.processStart ?? $0.liveProcessBirth) == birth }) else { return }
            performOnRegistration(record, movingWindows: Session.isUser(record.session)) { [weak self] current in
                guard let self else { return }
                guard processBirth(pid) == birth else { return }
                if Session.isUser(current.session) { releaseToUser(current, log: self.log); return }
                try? current.requestTermination(force: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.performOnRegistration(current) {
                        guard processBirth(pid) == birth else { return }
                        try? $0.requestTermination(force: true)
                    }
                }
            }
            return
        }
        guard processBirth(pid) == birth else { return }
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if processBirth(pid) == birth { kill(pid, SIGKILL) } }
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
        var records: [ManagedApp]
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
        let orphans = reapOrphanLaunches(deadSince: &orphanSince, registered: { pid, birth in
            records.contains { $0.pid == pid && ($0.processStart ?? $0.liveProcessBirth) == birth }
        }, final: true, log: log)
        // Apps the user sent here are quit only when the user asked for it (`stop --all`, a
        // signal, the menu). Any other shutdown (the last monitor unplugged, the display couldn't
        // be parked) gives them back instead: their windows follow the display's to the user's screen.
        if !(reason.hasPrefix("signal") || reason == "stopped from the menu bar") {
            for record in records where Session.isUser(record.session) { releaseToUser(record, log: log) }
            records.removeAll { Session.isUser($0.session) }
        }
        for record in records {
            do { try record.requestTermination(force: false) } catch { log("quit pid \(record.pid): \(error)") }
        }
        _ = waitFor(timeout: 2) { orphans.contains { processAlive($0) } ? nil : true }
        _ = waitFor(timeout: 3) { records.contains { $0.matchesProcess } ? nil : true }
        // Apps the user sent here are never force-quit (an unsaved-changes dialog is their work):
        // one still running goes back to the user's screen instead.
        let (userApps, agentApps) = (records.filter { Session.isUser($0.session) }, records.filter { !Session.isUser($0.session) })
        for record in userApps where record.matchesProcess { releaseToUser(record, log: log) }
        for record in agentApps where record.matchesProcess {
            do { try record.requestTermination(force: true) } catch { log("force quit pid \(record.pid): \(error)") }
        }
        _ = waitFor(timeout: 1) { agentApps.contains { $0.matchesProcess } ? nil : true }
        do {
            guard !agentApps.contains(where: { $0.matchesProcess }) else {
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
        // The apps are gone: now their taps can go.
        audioTaps?.shutdown()
        unlink(Paths.daemon.path)
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
    func compatibleDaemon() throws -> DaemonInfo? {
        guard let daemon = liveDaemon() else { return nil }
        guard !daemon.protocolMismatch else { throw daemonVersionError(daemon) }
        guard daemon.stopping != true else { throw CLIError("the backstage daemon is shutting down; try again") }
        return daemon
    }
    if let d = try compatibleDaemon() { return d }
    try Paths.ensure()
    // The running binary itself. Not argv[0]: invoked by bare name through PATH, that resolves
    // against the working directory, which may hold an unrelated `backstage` (a checkout).
    let selfPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path

    _ = try requestedDisplaySlot()   // a bad BACKSTAGE_DISPLAY is reported here, not as a failed start
    let logStart = (try? FileManager.default.attributesOfItem(atPath: Paths.log.path)[.size] as? UInt64) ?? 0
    func checkSpawn(_ status: Int32) throws {
        guard status == 0 else { throw CLIError("failed to spawn daemon: \(String(cString: strerror(status)))") }
    }
    var attr: posix_spawnattr_t?
    try checkSpawn(posix_spawnattr_init(&attr))
    defer { posix_spawnattr_destroy(&attr) }
    try checkSpawn(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)))
    var fa: posix_spawn_file_actions_t?
    try checkSpawn(posix_spawn_file_actions_init(&fa))
    defer { posix_spawn_file_actions_destroy(&fa) }
    try checkSpawn(posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0))
    try checkSpawn(posix_spawn_file_actions_addopen(&fa, 1, Paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600))
    try checkSpawn(posix_spawn_file_actions_addopen(&fa, 2, Paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600))
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(selfPath), strdup("__daemon"), nil]
    defer { for pointer in argv { free(pointer) } }
    guard argv[0] != nil, argv[1] != nil else { throw POSIXError(.ENOMEM) }
    try checkSpawn(posix_spawn(&pid, selfPath, &fa, &attr, argv, environ))
    var status: Int32 = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    repeat {
        if let info = try compatibleDaemon() { return info }
        if waitpid(pid, &status, WNOHANG) == pid {
            if let why = lastLoggedError(since: logStart) { throw CLIError(why) }
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

/// The last `"error"` the daemon wrote to its log after `offset` (it reports a failed start there).
private func lastLoggedError(since offset: UInt64) -> String? {
    guard let h = try? FileHandle(forReadingFrom: Paths.log) else { return nil }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    let pattern = try! NSRegularExpression(pattern: #""error" : "((?:[^"\\]|\\.)*)""#)
    guard let m = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data("\"\(text[r])\"".utf8), options: .fragmentsAllowed) as? String) ?? String(text[r])
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
    try rejectIncompatibleDaemon()
    var quit: [Int32] = []
    var allGone = true
    do {
        let lock = try Locks.session(session.id)
        defer { lock.release() }
        // A launch in this session that started before now gives up instead of registering.
        try lock.writeStamp(Date().timeIntervalSince1970)
        let mine = try AppStore.read().filter { Session.sameID($0.session, session.id) }
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
        // its app (up to 60 s, 120 s under load), `show` while it hands an app over, and waiting here would keep
        // client.lock, and with it every other session's launch, blocked that long. A daemon
        // left running stops itself after its idle timeout.
        let lifecycle: StateLock
        do { lifecycle = try StateLock("lifecycle.lock", nonblocking: true) }
        catch where StateLock.isBusy(error) { return "running (a launch or show is in progress in some session)" }
        defer { lifecycle.release() }
        let remaining = try AppStore.read()
        if !remaining.isEmpty {
            let mine = remaining.filter { Session.sameID($0.session, session) }.count
            let sent = remaining.filter { Session.isUser($0.session) }.count
            var parts: [String] = []
            if mine > 0 { parts.append("\(plural(mine, "app")) of this session didn't quit") }
            if remaining.count > mine + sent { parts.append("\(plural(remaining.count - mine - sent, "app")) in other sessions") }
            if sent > 0 { parts.append("\(plural(sent, "app")) the user sent backstage") }
            return "running (" + parts.joined(separator: "; ") + ")"
        }
        guard let d = readJSON(Paths.daemon, DaemonInfo.self), d.matchesProcess else { return "not running" }
        // The user pinned the icon: only `stop --all` (or the menu) takes it down.
        if Settings.load().keep { return "running (Keep in Menu Bar is on; `backstage stop --all` stops it)" }
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
            // Apps the user sent backstage are asked to quit, never forced: with no daemon there's
            // no display, so one that stays (an unsaved-changes dialog) is already on their screen.
            let sent = records.filter { Session.isUser($0.session) }
            for record in sent { try? record.requestTermination(force: false) }
            guard quitApps(records.filter { !Session.isUser($0.session) }) else { throw CLIError("some managed apps did not quit") }
            _ = waitFor(timeout: 3) { sent.contains { $0.matchesProcess } ? nil : true }
            try AppStore.update { $0.removeAll { Session.isUser($0.session) } }
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
