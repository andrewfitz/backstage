import Foundation
import AppKit
import CoreGraphics
import CVirtualDisplay

let kVendor: UInt32 = 0xB57A
let kProduct: UInt32 = 0x0001

func activeDisplays() -> [CGDirectDisplayID] {
    var capacity: UInt32 = 16
    while true {
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(capacity, &ids, &count) == .success else { return [] }
        if count < capacity { return Array(ids.prefix(Int(count))) }
        capacity *= 2
    }
}

/// True for every backstage display: this daemon's and those of daemons with other homes.
func isOurDisplay(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == kVendor && CGDisplayModelNumber(id) == kProduct
}

/// The stand-in screen backstage puts up while no real display is attached (the monitor off,
/// a headless Mac, a remote desktop or VNC session). It's one of the *user's* screens, not a
/// hidden one, so everything else treats it like a monitor: macOS makes it the main display,
/// and remote viewers see a normal desktop instead of the hidden display. One fixed identity.
let kStandInProduct: UInt32 = 0x0002
let standInSerial: UInt32 = 0x4253_0100
let standInName = "Backstage Stand-in"
func isStandInDisplay(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == kVendor && CGDisplayModelNumber(id) == kStandInProduct
}

/// Active display bounds for one check. Refresh after changing the arrangement.
struct DisplayGeometry {
    let ids = activeDisplays()
    let bounds: [CGDirectDisplayID: CGRect]

    init() {
        bounds = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGDisplayBounds($0)) })
    }

    func classified() -> (users: [CGRect], agents: [CGDirectDisplayID: CGRect]) {
        var users: [CGRect] = []
        var agents: [CGDirectDisplayID: CGRect] = [:]
        for id in ids {
            guard let frame = bounds[id] else { continue }
            if isOurDisplay(id) { agents[id] = frame }
            else if CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay { users.append(frame) }
        }
        return (users, agents)
    }
}

/// The eight backstage displays. macOS registers every new display identity (vendor, product,
/// serial) for good, in ColorSync and in WindowServer's display list, and ColorSync slows down
/// as its list grows: so backstage only ever uses these eight serials, never one per home.
/// 1 is the default home's; 2-6 other homes' (then the default daemon's extra displays);
/// 7-8 are for backstage's own test suites (docs/MULTI_DISPLAY_PLAN.md).
let displaySlots = 1...8
let sharedDisplaySlots = 2...6
func displaySerial(slot: Int) -> UInt32 { 0x4253_0000 + UInt32(slot) }
func displaySlot(serial: UInt32) -> Int? {
    let slot = Int(serial) - 0x4253_0000
    return displaySlots.contains(slot) ? slot : nil
}

/// The display this home asks for: BACKSTAGE_DISPLAY, else 1 for the default home, else nil
/// (the lowest free shared display).
func requestedDisplaySlot() throws -> Int? {
    if let raw = ProcessInfo.processInfo.environment["BACKSTAGE_DISPLAY"], !raw.isEmpty {
        guard let n = Int(raw), displaySlots.contains(n) else { throw CLIError("BACKSTAGE_DISPLAY must be a number from 1 to 8") }
        return n
    }
    return Paths.isDefaultHome ? 1 : nil
}

/// Every online display (active, asleep or mirrored), or nil if macOS won't say.
func onlineDisplays() -> [CGDirectDisplayID]? {
    var capacity: UInt32 = 16
    while true {
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success else { return nil }
        if count < capacity { return Array(ids.prefix(Int(count))) }
        capacity *= 2
    }
}

/// The backstage display slots in use right now, by any home. Nil if macOS won't list displays.
func displaySlotsInUse() -> Set<Int>? {
    onlineDisplays().map { Set($0.filter(isOurDisplay).compactMap { displaySlot(serial: CGDisplaySerialNumber($0)) }) }
}

/// How two rectangles meet. Displays that share an edge let the cursor (and the Dock) cross;
/// displays that meet only at a corner point don't.
enum Contact { case apart, corner, edge, overlap }
func contact(_ a: CGRect, _ b: CGRect) -> Contact {
    let dx = min(a.maxX, b.maxX) - max(a.minX, b.minX)
    let dy = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    if dx < 0 || dy < 0 { return .apart }
    if dx > 0 && dy > 0 { return .overlap }
    return dx == 0 && dy == 0 ? .corner : .edge
}

/// Where a backstage display is parked at `r`, it meets every other display (the user's and other
/// backstage displays) at most at a corner point.
func isParkable(_ r: CGRect, among others: [CGRect]) -> Bool {
    others.allSatisfy { let c = contact(r, $0); return c == .apart || c == .corner }
}

/// Where a backstage display may stay: it meets the user's displays at most at a corner point,
/// and overlaps no other backstage display. Sharing an edge with another backstage display is
/// harmless (the cursor guard covers them all), and macOS puts every new display edge to edge
/// with the others for a moment before its daemon parks it: moving away from that would just
/// reshuffle the chain.
func mayStay(_ r: CGRect, users: [CGRect], others: [CGRect]) -> Bool {
    isParkable(r, among: users) && others.allSatisfy { contact(r, $0) != .overlap }
}

/// Where to park a display of `size`: diagonally off the bottom-right corner of the user's
/// desktop; if another backstage display is there, chained diagonally off the bottom-right
/// corner of a backstage display; failing both, off the bottom-right corner of everything.
func parkingSpot(size: CGSize, users: [CGRect], others: [CGRect]) -> CGPoint? {
    let u = users.reduce(CGRect.null) { $0.union($1) }
    guard !u.isNull else { return nil }
    let all = users + others
    func key(_ p: CGPoint) -> (CGFloat, CGFloat) { (p.x + p.y, p.x) }
    let candidates = [CGPoint(x: u.maxX, y: u.maxY)]
        + others.map { CGPoint(x: $0.maxX, y: $0.maxY) }.sorted { key($0) < key($1) }
    if let p = candidates.first(where: { isParkable(CGRect(origin: $0, size: size), among: all) }) { return p }
    let everything = all.reduce(u) { $0.union($1) }
    return CGPoint(x: everything.maxX, y: everything.maxY)
}

/// An flock shared by every backstage process of this user, whatever its BACKSTAGE_HOME (in /tmp,
/// not TMPDIR, which a caller may override). Nil if unavailable.
final class UserLock {
    private var fd: Int32 = -1
    init?(_ name: String, nonblocking: Bool = false) {
        fd = open("/tmp/backstage-\(getuid())-\(name)", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            release()
            return nil
        }
        while flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            if errno == EINTR { continue }
            close(fd); fd = -1
            return nil
        }
    }
    func release() { if fd >= 0 { close(fd); fd = -1 } }
    deinit { release() }
}

/// Bounds (global, top-left origin) of every display the user can actually see.
func userDisplayBounds(from ids: [CGDirectDisplayID] = activeDisplays()) -> [CGRect] {
    ids
        .filter { !isOurDisplay($0) && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        .map { CGDisplayBounds($0) }
}

/// Point size of the user's main display (the one with the menu bar), never backstage's own.
func mainDisplaySize() -> CGSize? {
    let main = CGMainDisplayID()
    if !isOurDisplay(main), CGDisplayIsActive(main) != 0 { return CGDisplayBounds(main).size }
    return userDisplayBounds().first?.size
}

/// The NSScreen for a display. Its `visibleFrame` leaves out a secondary display's menu bar
/// only once the process has an NSApplication, so this makes sure there is one.
func nsScreen(_ id: CGDirectDisplayID) -> NSScreen? {
    _ = NSApplication.shared
    return NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }
}

/// The Dock's own window: as large as the display the Dock is on (nil if the Dock isn't running).
/// The Dock's PID is looked up only when it changes: asking LaunchServices can be slow while apps
/// launch and quit, and this runs on the daemon's guard loop.
private var dockPid: pid_t = 0
func dockWindowBounds(from onscreen: [[String: Any]]?) -> CGRect? {
    if dockPid == 0 || kill(dockPid, 0) != 0 {
        dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
    }
    let dock = dockPid
    guard dock != 0 else { return nil }
    let level = Int(CGWindowLevelForKey(.dockWindow))
    func dockBounds(in windows: [[String: Any]]) -> CGRect? {
        windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == dock && ($0[kCGWindowLayer as String] as? Int) == level }
            .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
    }
    if let onscreen, let bounds = dockBounds(in: onscreen) { return bounds }
    // Containment excludes desktop elements. If the shared list has no Dock window,
    // preserve the Dock guard's lookup in the complete on-screen list.
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    return dockBounds(in: windows)
}

/// A backstage display, held by its display host process (DisplayHost.swift). Dropping it
/// ends the host, which removes the display; a daemon that exits leaves its primary display's
/// host to linger for the next daemon (`DisplayHosts.homeLinger`).
final class AgentDisplay {
    let id: CGDirectDisplayID
    var bounds: CGRect { CGDisplayBounds(id) }
    let hostID: String
    let hostPID: pid_t
    let hostStart: UInt64
    /// Taken over from the previous daemon's host: already online, parked and sized.
    let adopted: Bool

    /// `width`×`height` is the size in points; `scale` (1 or 2) is the backing scale factor.
    /// Which slot to take: the home's (BACKSTAGE_DISPLAY, or 1 for the default home, else the
    /// lowest free shared one), exactly one (an extra display asked for by number), or the
    /// lowest free of some (`launch --display new`).
    enum SlotChoice { case home, exactly(Int), lowestFree([Int]) }

    /// A new display, in a new host. `linger`: how long the host keeps it once this daemon is gone.
    init(width: UInt32, height: UInt32, scale: UInt32, choice: SlotChoice = .home, linger: Double = 0) throws {
        let (info, pid) = try spawnDisplayHost(width: width, height: height, scale: scale, choice: choice,
                                               role: { if case .home = choice { return "home" } else { return "extra" } }(), linger: linger)
        id = info.displayID
        hostID = info.id
        hostPID = pid
        hostStart = info.start
        adopted = false
        slot = info.slot
        serial = displaySerial(slot: info.slot)
        size = (width, height, scale)
    }

    /// The display of a host the previous daemon left (adoptHomeDisplayHost).
    init(adopting info: DisplayHostInfo) {
        id = info.displayID
        hostID = info.id
        hostPID = info.pid
        hostStart = info.start
        adopted = true
        slot = info.slot
        serial = displaySerial(slot: info.slot)
        size = (info.width, info.height, info.scale)
    }

    /// The host is running (reaping it if it exited as this process's child).
    var hostAlive: Bool {
        var status: Int32 = 0
        _ = waitpid(hostPID, &status, WNOHANG)
        return processBirth(hostPID) == hostStart
    }

    /// Remove the display now: end its host and wait for the display to go.
    func remove() { DisplayHosts.end((hostPID, hostStart), id: hostID, displayID: id) }

    deinit { remove() }
    let size: (width: UInt32, height: UInt32, scale: UInt32)
    let slot: Int
    let serial: UInt32

    /// macOS remembers the last mode used for this display (vendor/product/serial), so a display
    /// that last ran at 1x can come back at 1x even with HiDPI on, and the other way round.
    /// Select the mode explicitly, for this login session only (nothing is saved).
    func selectMode() -> Bool {
        func wanted(_ m: CGDisplayMode) -> Bool {
            m.width == Int(size.width) && m.height == Int(size.height)
                && m.pixelWidth == Int(size.width * size.scale) && m.pixelHeight == Int(size.height * size.scale)
        }
        if let current = CGDisplayCopyDisplayMode(id), wanted(current) { return true }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let mode = modes.first(where: wanted) else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        guard CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }

    /// True while the display meets the user's displays at most at a corner point and overlaps no
    /// other backstage display (see `mayStay`): the cursor essentially can't wander onto it (and
    /// the daemons warp it back if it does), and the Dock, which follows the cursor to a display's
    /// bottom edge and moves to a display arranged below its own, stays on the user's screen.
    func isParked(users: [CGRect], agents: [CGDirectDisplayID: CGRect]) -> Bool {
        guard let here = agents[id], !here.isEmpty else { return false }
        return mayStay(here, users: users, others: agents.compactMap { $0.key == id ? nil : $0.value })
    }

    /// Park the display diagonally off the bottom-right corner of the user's desktop, or chained
    /// off another backstage display's corner when that spot is taken (see `parkingSpot`). Only
    /// this display is ever moved. With `force` (startup) it goes to the best spot even if where
    /// macOS put it would do; otherwise a parked display stays put, so daemons never chase each
    /// other round the chain. Parking holds a lock shared by every backstage process, so no two
    /// daemons pick the same spot at once, and reads the result back: macOS shoves a display
    /// asked onto an occupied spot (an older daemon's) to wherever it fits, often edge to edge.
    @discardableResult
    func park(force: Bool = false) -> Bool {
        guard let lock = UserLock("park.lock") else { return false }
        defer { lock.release() }
        // The size it will have: a display can come up in the mode last used with its identity.
        let target = CGSize(width: Int(size.width), height: Int(size.height))
        for attempt in 0..<5 {
            let (users, agents) = DisplayGeometry().classified()
            guard let here = agents[id] else { return false }
            let others = agents.compactMap { $0.key == id ? nil : $0.value }
            guard let spot = parkingSpot(size: target, users: users, others: others),
                  let x = Int32(exactly: spot.x), let y = Int32(exactly: spot.y) else { return false }
            if !here.isEmpty, mayStay(here, users: users, others: others), !force || attempt > 0 || here.origin == spot { return true }
            var cfg: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
            guard CGConfigureDisplayOrigin(cfg, id, x, y) == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else { return false }
            for _ in 0..<25 {
                if bounds.origin == spot { break }
                usleep(20_000)
            }
        }
        let (users, agents) = DisplayGeometry().classified()
        return isParked(users: users, agents: agents)
    }
}

/// Info about the running daemon's display, validated against the live display list.
func liveDaemon() -> DaemonInfo? {
    guard let info = readJSON(Paths.daemon, DaemonInfo.self), info.matchesProcess else { return nil }
    return liveDisplay(info)
}

/// Refresh the displays in a daemon record after the caller has verified the process identity.
func liveDisplay(_ checkedInfo: DaemonInfo) -> DaemonInfo? {
    var info = checkedInfo
    guard isOurDisplay(info.displayID), CGDisplayIsActive(info.displayID) != 0 else { return nil }
    let b = CGDisplayBounds(info.displayID)
    guard !b.isEmpty else { return nil }
    if let entries = info.displays {
        guard let primary = entries.first, primary.displayID == info.displayID,
              displaySlot(serial: CGDisplaySerialNumber(primary.displayID)) == primary.slot else { return nil }
        info.displays = entries.compactMap { entry in
            let id = entry.displayID
            let bounds: CGRect
            if id == primary.displayID {
                guard entry.slot == primary.slot else { return nil }
                bounds = b
            } else {
                guard isOurDisplay(id), CGDisplayIsActive(id) != 0,
                      displaySlot(serial: CGDisplaySerialNumber(id)) == entry.slot else { return nil }
                bounds = CGDisplayBounds(id)
                guard !bounds.isEmpty else { return nil }
            }
            var live = entry
            live.x = bounds.minX; live.y = bounds.minY; live.width = bounds.width; live.height = bounds.height
            return live
        }
    }
    info.x = b.origin.x; info.y = b.origin.y; info.width = b.width; info.height = b.height
    return info
}
