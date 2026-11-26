import Foundation
import CoreGraphics
import CVirtualDisplay

// A backstage display lives in a small process of its own, the display host
// (`backstage __display-host`), not in the daemon. Creating or removing a display makes macOS
// reconfigure every display, which can blank the user's monitor for a moment. With the display
// in its own process, a daemon restart (`stop --all && start`, an upgrade) can leave it in place:
// the exiting daemon's host lingers for a few seconds (the owner's `linger`) and the next daemon
// adopts it, so the user's monitor sees no change at all.
//
// The host does as little as possible: it creates the display, then checks a lease every
// 0.25 s. It exits (taking the display with it) when its display goes offline, when it's
// signalled (the daemon removing a display), or once its owner has been gone for `linger`
// seconds. An owner it can't read (a deleted home) counts as gone. The decision to exit and a
// daemon's claim on a host are both made under the host's lock, so a host never vanishes under a
// daemon that has just adopted it.

/// Bump when a host can no longer serve a daemon of the other version: the daemon then replaces
/// it (one display reconfiguration).
let displayHostProtocol = 1

/// What a host publishes once its display is online: `hosts/<id>.json`.
struct DisplayHostInfo: Codable {
    var proto: Int
    var id: String
    var pid: Int32
    var start: UInt64
    var slot: Int
    var displayID: UInt32
    var width: UInt32
    var height: UInt32
    var scale: UInt32
    var role: String            // "home" (the daemon's primary display) or "extra"
}

/// The daemon holding a host: `hosts/<id>.owner`, written by the daemon (before it starts the
/// host, and again when a new daemon adopts it).
struct DisplayHostOwner: Codable {
    var pid: Int32
    var start: UInt64
    /// Seconds the host keeps the display after its owner is gone.
    var linger: Double
}

enum DisplayHosts {
    static var dir: URL { Paths.dir.appendingPathComponent("hosts") }
    static func info(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    static func owner(_ id: String) -> URL { dir.appendingPathComponent("\(id).owner") }
    /// `create: false` (the host's checks): a deleted home stays deleted.
    static func lock(_ id: String, create: Bool = true) throws -> StateLock { try StateLock("hosts/\(id).lock", create: create) }

    static func remove(_ id: String) {
        for url in [info(id), owner(id), dir.appendingPathComponent("\(id).lock")] { try? FileManager.default.removeItem(at: url) }
    }

    static func all() -> [DisplayHostInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { readJSON(dir.appendingPathComponent($0), DisplayHostInfo.self) }
    }

    static func alive(_ host: DisplayHostInfo) -> Bool { processBirth(host.pid) == host.start }

    /// How long the daemon's primary display outlives the daemon: BACKSTAGE_DISPLAY_LINGER
    /// seconds, by default 15 in ~/.backstage (enough for `stop --all && start` or an upgrade
    /// between them) and 0 elsewhere, so a test's display goes with its daemon.
    static func homeLinger() -> Double {
        if let value = ProcessInfo.processInfo.environment["BACKSTAGE_DISPLAY_LINGER"],
           let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(seconds, 300) }
        return Paths.isDefaultHome ? 15 : 0
    }

    /// End a host now (its display goes with it), and wait up to `wait` s for the display to go.
    static func end(_ host: (pid: pid_t, start: UInt64), id: String, displayID: CGDirectDisplayID?, wait: Double = 2) {
        if processBirth(host.pid) == host.start { kill(host.pid, SIGTERM) }
        var status: Int32 = 0
        _ = waitFor(timeout: wait) { () -> Bool? in
            _ = waitpid(host.pid, &status, WNOHANG)   // reap it if it's this process's child
            let gone = processBirth(host.pid) != host.start
            let offline = displayID.map { !(onlineDisplays() ?? []).contains($0) } ?? true
            return gone && offline ? true : nil
        }
        if processBirth(host.pid) == host.start { kill(host.pid, SIGKILL); _ = waitpid(host.pid, &status, WNOHANG) }
        remove(id)
    }
}

/// Create a backstage display in this process (the host): the slot chosen and the display
/// created under a lock shared by every home, held until the display is online, so two daemons
/// can't take the same slot.
func createVirtualDisplay(width: UInt32, height: UInt32, scale: UInt32, choice: AgentDisplay.SlotChoice) throws -> (CGVirtualDisplay, Int) {
    // Each attempt locks only while it chooses and creates; a successful one keeps the lock
    // until the display is online. Waiting for a busy slot never holds it, so other homes
    // and the daemon's own extra displays aren't stalled meanwhile.
    var held: UserLock?
    defer { held?.release() }
    func locked(_ body: () throws -> (CGVirtualDisplay, Int)?) throws -> (CGVirtualDisplay, Int)? {
        guard let lock = UserLock("displays.lock") else { throw CLIError("cannot lock the backstage displays for this user") }
        let result = try body()
        if result != nil { held = lock } else { lock.release() }
        return result
    }
    func make(_ slot: Int) -> CGVirtualDisplay? {
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue.main
        d.name = DisplayRegistry.displayName
        d.maxPixelsWide = width * scale
        d.maxPixelsHigh = height * scale
        // 100 points per inch, whatever the scale
        d.sizeInMillimeters = CGSize(width: Double(width) * 0.254, height: Double(height) * 0.254)
        d.vendorID = kVendor
        d.productID = kProduct
        d.serialNum = displaySerial(slot: slot)
        d.terminationHandler = { _, _ in
            eprint("virtual display terminated by system")
            exit(1)
        }
        return CGVirtualDisplay(descriptor: d)
    }
    func lowestFree(_ slots: [Int]) throws -> (CGVirtualDisplay, Int)? {
        try locked {
            guard let inUse = displaySlotsInUse() else { throw CLIError("cannot list the online displays") }
            for slot in slots where !inUse.contains(slot) { if let vd = make(slot) { return (vd, slot) } }
            return nil
        }
    }
    func exactly(_ wanted: Int, wait: Double) throws -> (CGVirtualDisplay, Int)? {
        // Right after a stop, the old display can still be online for a moment.
        try waitFor(timeout: wait, interval: 0.25) { () throws -> (CGVirtualDisplay, Int)? in
            try locked {
                guard let inUse = displaySlotsInUse() else { throw CLIError("cannot list the online displays") }
                guard !inUse.contains(wanted), let vd = make(wanted) else { return nil }
                return (vd, wanted)
            }
        }
    }
    var created: (CGVirtualDisplay, Int)?
    switch choice {
    case .home:
        if let wanted = try requestedDisplaySlot() {
            created = try exactly(wanted, wait: 5)
            guard created != nil else { throw CLIError("display \(wanted) is in use") }
        } else {
            created = try lowestFree(Array(sharedDisplaySlots))
            guard created != nil else {
                throw CLIError("displays \(sharedDisplaySlots.lowerBound)-\(sharedDisplaySlots.upperBound) are all in use (BACKSTAGE_DISPLAY picks one)")
            }
        }
    case .exactly(let wanted):
        created = try exactly(wanted, wait: 0)
        guard created != nil else { throw CLIError("display \(wanted) is in use") }
    case .lowestFree(let slots):
        created = try lowestFree(slots)
        guard created != nil else { throw CLIError("no free display left (\(slots.map(String.init).joined(separator: ", ")) are in use)") }
    }
    guard let (vd, slot) = created else { throw CLIError("CGVirtualDisplay init failed") }
    guard let mode = CGVirtualDisplayMode(width: width, height: height, refreshRate: 30) else {
        throw CLIError("CGVirtualDisplay mode init failed")
    }
    let s = CGVirtualDisplaySettings()
    s.hiDPI = scale > 1 ? 1 : 0
    s.modes = [mode]
    guard vd.apply(s) else { throw CLIError("CGVirtualDisplay applySettings failed") }
    // A virtual display comes online once it has a mode; only then can others see the slot taken.
    guard waitFor(timeout: 5, { (onlineDisplays() ?? []).contains(vd.displayID) ? true : nil }) != nil else {
        throw CLIError("could not bring the agent display online")
    }
    return (vd, slot)
}

extension AgentDisplay.SlotChoice {
    var argument: String {
        switch self {
        case .home: return "home"
        case .exactly(let slot): return "exactly:\(slot)"
        case .lowestFree(let slots): return "lowest:" + slots.map(String.init).joined(separator: ",")
        }
    }

    init?(argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("home"?, nil): self = .home
        case ("exactly"?, let n?): guard let slot = Int(n) else { return nil }; self = .exactly(slot)
        case ("lowest"?, let list?):
            let slots = list.split(separator: ",").compactMap { Int($0) }
            guard !slots.isEmpty else { return nil }
            self = .lowestFree(slots)
        default: return nil
        }
    }
}

/// `backstage __display-host --id ID --width W --height H --scale S --choice C --role R`:
/// create the display, report `{"ok", "slot", "displayID"}` (or `{"ok": false, "error"}`) as one
/// line on stdout, then hold the display until the lease ends (see the top of this file).
func runDisplayHost(_ args: Args) -> Never {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    func report(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object), var line = String(data: data, encoding: .utf8) {
            line += "\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        // Nothing more goes to the daemon's pipe.
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, STDOUT_FILENO); close(null) }
    }
    guard let id = args.opt("id"), !id.isEmpty, !id.contains("/"),
          let width = args.opt("width").flatMap({ UInt32($0) }), let height = args.opt("height").flatMap({ UInt32($0) }),
          let scale = args.opt("scale").flatMap({ UInt32($0) }),
          let choice = args.opt("choice").flatMap({ AgentDisplay.SlotChoice(argument: $0) }),
          let role = args.opt("role"), role == "home" || role == "extra" else {
        report(["ok": false, "error": "usage: backstage __display-host --id ID --width W --height H --scale S --choice C --role home|extra"])
        exit(2)
    }
    let display: CGVirtualDisplay
    let slot: Int
    do {
        (display, slot) = try createVirtualDisplay(width: width, height: height, scale: scale, choice: choice)
    } catch {
        report(["ok": false, "error": "\(error)"])
        exit(1)
    }
    let me = getpid()
    let info = DisplayHostInfo(proto: displayHostProtocol, id: id, pid: me, start: processBirth(me) ?? 0, slot: slot,
                               displayID: display.displayID, width: width, height: height, scale: scale, role: role)
    do { try writeJSON(DisplayHosts.info(id), info) } catch {
        report(["ok": false, "error": "couldn't record the display host: \(error)"])
        exit(1)
    }
    (try? DisplayHosts.lock(id))?.release()   // the lock file exists from now on
    report(["ok": true, "slot": slot, "displayID": display.displayID])

    var ownerGoneSince: Double?
    var offlineSince: Double?
    let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
        let now = ProcessInfo.processInfo.systemUptime
        // Offline for 2 s straight (not one missed sample, as around sleep and wake): it's gone.
        if (onlineDisplays() ?? [display.displayID]).contains(display.displayID) {
            offlineSince = nil
        } else {
            let since = offlineSince ?? now
            offlineSince = since
            if now - since >= 2 { DisplayHosts.remove(id); exit(0) }
        }
        // The owner, read and acted on under the host's lock (a claim takes the same lock).
        guard let lock = try? DisplayHosts.lock(id, create: false) else { exit(0) }   // the home is gone
        defer { lock.release() }
        let owner = readJSON(DisplayHosts.owner(id), DisplayHostOwner.self)
        if let owner, processBirth(owner.pid) == owner.start {
            ownerGoneSince = nil
            return
        }
        let since = ownerGoneSince ?? now
        ownerGoneSince = since
        if now - since >= (owner?.linger ?? 0) {
            DisplayHosts.remove(id)
            withExtendedLifetime(display) {}
            exit(0)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    withExtendedLifetime(display) { RunLoop.main.run() }
    exit(0)
}

/// Start a display host as a child of this process, in its own session (a signal to the daemon
/// never reaches it), and wait for its report. Records this process as its owner first.
func spawnDisplayHost(width: UInt32, height: UInt32, scale: UInt32, choice: AgentDisplay.SlotChoice,
                      role: String, linger: Double) throws -> (info: DisplayHostInfo, pid: pid_t) {
    try Paths.ensureDirectory(DisplayHosts.dir)
    let id = UUID().uuidString
    let me = getpid()
    try writeJSON(DisplayHosts.owner(id), DisplayHostOwner(pid: me, start: processBirth(me) ?? 0, linger: linger))
    let selfPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var pipeFDs: [Int32] = [0, 0]
    guard pipe(&pipeFDs) == 0 else { DisplayHosts.remove(id); throw CLIError("couldn't start the display host: \(String(cString: strerror(errno)))") }
    defer { close(pipeFDs[0]) }
    func check(_ status: Int32) throws {
        guard status == 0 else { throw CLIError("couldn't start the display host: \(String(cString: strerror(status)))") }
    }
    var pid: pid_t = 0
    do {
        defer { close(pipeFDs[1]) }
        var attr: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attr))
        defer { posix_spawnattr_destroy(&attr) }
        // Its own session, and none of the daemon's descriptors (locks, sockets) but these three:
        // it outlives the daemon.
        try check(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var fa: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fa))
        defer { posix_spawn_file_actions_destroy(&fa) }
        try check(posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&fa, pipeFDs[1], 1))
        try check(posix_spawn_file_actions_addopen(&fa, 2, Paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600))
        let arguments = [selfPath, "__display-host", "--id", id, "--width", String(width), "--height", String(height),
                         "--scale", String(scale), "--choice", choice.argument, "--role", role]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        try check(posix_spawn(&pid, selfPath, &fa, &attr, argv, environ))
    } catch {
        DisplayHosts.remove(id)
        throw error
    }
    // One line: creation waits up to 5 s for a slot and 5 s for the display to come online.
    var output = Data()
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !output.contains(UInt8(ascii: "\n")) && ProcessInfo.processInfo.systemUptime < deadline {
        var poller = pollfd(fd: pipeFDs[0], events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, 250)
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { continue }
        let n = read(pipeFDs[0], &buffer, buffer.count)
        if n <= 0 { break }
        output.append(contentsOf: buffer[0..<n])
    }
    let line = output.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? Data()
    let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    if reply?["ok"] as? Bool == true, let info = readJSON(DisplayHosts.info(id), DisplayHostInfo.self), info.pid == pid {
        return (info, pid)
    }
    DisplayHosts.end((pid, processBirth(pid) ?? 0), id: id, displayID: nil, wait: 1)
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
    throw CLIError(reply?["error"] as? String ?? "the display host didn't start (see \(Paths.log.path))")
}

/// At startup: take over this home's primary display from a host the previous daemon left
/// lingering, if it fits (same protocol, slot, size and scale, still online). Hosts that don't
/// fit are ended, so their slot is free for a new one.
func adoptHomeDisplayHost(width: UInt32, height: UInt32, scale: UInt32, linger: Double, log: (String) -> Void) -> DisplayHostInfo? {
    let wantedSlot = (try? requestedDisplaySlot()) ?? nil
    let me = getpid()
    var adopted: DisplayHostInfo?
    for host in DisplayHosts.all() {
        guard let lock = try? DisplayHosts.lock(host.id) else { continue }
        // Re-read under the lock: the host may have just decided to exit.
        guard let current = readJSON(DisplayHosts.info(host.id), DisplayHostInfo.self), DisplayHosts.alive(current) else {
            lock.release()
            DisplayHosts.remove(host.id)
            continue
        }
        // Another live process holds it (daemon.lock should make this impossible): never touch it.
        if let owner = readJSON(DisplayHosts.owner(current.id), DisplayHostOwner.self),
           owner.pid != me, processBirth(owner.pid) == owner.start {
            lock.release()
            log("leaving display host pid \(current.pid) alone: process \(owner.pid) still holds it")
            continue
        }
        let fits = adopted == nil && current.proto == displayHostProtocol && current.role == "home"
            && current.width == width && current.height == height && current.scale == scale
            && (wantedSlot.map { $0 == current.slot } ?? true)
            && (onlineDisplays() ?? []).contains(current.displayID)
            && CGDisplaySerialNumber(current.displayID) == displaySerial(slot: current.slot)
        if fits, (try? writeJSON(DisplayHosts.owner(current.id), DisplayHostOwner(pid: me, start: processBirth(me) ?? 0, linger: linger))) != nil {
            lock.release()
            adopted = current
            log("adopted display \(current.slot) (id \(current.displayID)) from display host pid \(current.pid): no display change")
            continue
        }
        lock.release()
        log("ending display host pid \(current.pid) (display \(current.slot)): " + (current.proto != displayHostProtocol ? "another protocol" : "doesn't fit this daemon"))
        DisplayHosts.end((current.pid, current.start), id: current.id, displayID: current.displayID)
    }
    return adopted
}
