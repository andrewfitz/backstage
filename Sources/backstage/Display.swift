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

/// Bounds of the backstage displays other than `own` (other homes' daemons).
func otherAgentDisplayBounds(excluding own: CGDirectDisplayID) -> [CGRect] {
    activeDisplays().filter { $0 != own && isOurDisplay($0) }.map { CGDisplayBounds($0) }
}

/// Serial numbers for this home's display, best first. Each BACKSTAGE_HOME has its own daemon and
/// so its own display, and two displays with the same vendor/product/serial can't coexist. The
/// first is stable per home (FNV-1a of the resolved path): macOS remembers a display's mode and
/// arrangement by its identity. The others are fallbacks for a clash with another home's.
/// Never 0 or 1 (1 is what every display had before serials were per home).
func displaySerials(home: URL = Paths.dir) -> [UInt32] {
    let path = home.resolvingSymlinksInPath().standardizedFileURL.path
    return (0..<4).map { salt in
        var h: UInt32 = 2_166_136_261
        for byte in (salt == 0 ? path : "\(path)#\(salt)").utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        return h > 1 ? h : h + 2
    }
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
/// not TMPDIR, which a caller may override). Nil if unavailable: callers go on without it.
final class UserLock {
    private var fd: Int32 = -1
    init?(_ name: String, nonblocking: Bool = false) {
        fd = open("/tmp/backstage-\(getuid())-\(name)", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
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
func userDisplayBounds() -> [CGRect] {
    activeDisplays()
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
func dockWindowBounds() -> CGRect? {
    if dockPid == 0 || kill(dockPid, 0) != 0 {
        dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
    }
    let dock = dockPid
    guard dock != 0, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let level = Int(CGWindowLevelForKey(.dockWindow))
    return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == dock && ($0[kCGWindowLayer as String] as? Int) == level }
        .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
}

/// Holds the private CGVirtualDisplay alive. Dropping it removes the display.
final class AgentDisplay {
    let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }
    var bounds: CGRect { CGDisplayBounds(id) }

    /// `width`×`height` is the size in points; `scale` (1 or 2) is the backing scale factor.
    init(width: UInt32, height: UInt32, scale: UInt32) throws {
        // Skip a serial another home's display already uses (a hash clash): it can't be created twice.
        let inUse = Set(activeDisplays().filter(isOurDisplay).map { CGDisplaySerialNumber($0) })
        var created: (CGVirtualDisplay, UInt32)?
        for serial in displaySerials() where !inUse.contains(serial) {
            let d = CGVirtualDisplayDescriptor()
            d.queue = DispatchQueue.main
            d.name = "Backstage (agent display)"
            d.maxPixelsWide = width * scale
            d.maxPixelsHigh = height * scale
            // 100 points per inch, whatever the scale
            d.sizeInMillimeters = CGSize(width: Double(width) * 0.254, height: Double(height) * 0.254)
            d.vendorID = kVendor
            d.productID = kProduct
            d.serialNum = serial
            d.terminationHandler = { _, _ in eprint("virtual display terminated by system") }
            if let vd = CGVirtualDisplay(descriptor: d) { created = (vd, serial); break }
        }
        guard let (vd, serial) = created else { throw CLIError("CGVirtualDisplay init failed") }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = scale > 1 ? 1 : 0
        s.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 30)]
        guard vd.apply(s) else { throw CLIError("CGVirtualDisplay applySettings failed") }
        display = vd
        self.serial = serial
        size = (width, height, scale)
    }
    let size: (width: UInt32, height: UInt32, scale: UInt32)
    let serial: UInt32

    /// macOS remembers the last mode used for this display (vendor/product/serial), so a display
    /// that last ran at 1x can come back at 1x even with HiDPI on, and the other way round.
    /// Select the mode explicitly, for this login session only (nothing is saved).
    func selectMode() -> Bool {
        func wanted(_ m: CGDisplayMode) -> Bool {
            m.width == Int(size.width) && m.height == Int(size.height) && m.pixelWidth == Int(size.width * size.scale)
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
    var isParked: Bool { mayStay(bounds, users: userDisplayBounds(), others: otherAgentDisplayBounds(excluding: id)) }

    /// Park the display diagonally off the bottom-right corner of the user's desktop, or chained
    /// off another backstage display's corner when that spot is taken (see `parkingSpot`). Only
    /// this display is ever moved. With `force` (startup) it goes to the best spot even if where
    /// macOS put it would do; otherwise a parked display stays put, so daemons never chase each
    /// other round the chain. Parking holds a lock shared by every backstage process, so no two
    /// daemons pick the same spot at once, and reads the result back: macOS shoves a display
    /// asked onto an occupied spot (an older daemon's) to wherever it fits, often edge to edge.
    @discardableResult
    func park(force: Bool = false) -> Bool {
        let lock = UserLock("park.lock")
        defer { lock?.release() }
        for attempt in 0..<5 {
            let users = userDisplayBounds(), others = otherAgentDisplayBounds(excluding: id)
            let here = bounds
            // The size it will have: a display can come up in the mode last used with its identity.
            let target = CGSize(width: Int(size.width), height: Int(size.height))
            guard let spot = parkingSpot(size: target, users: users, others: others),
                  let x = Int32(exactly: spot.x), let y = Int32(exactly: spot.y) else { return false }
            if mayStay(here, users: users, others: others), !force || attempt > 0 || here.origin == spot { return true }
            var cfg: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
            guard CGConfigureDisplayOrigin(cfg, id, x, y) == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else { return false }
            for _ in 0..<25 where bounds.origin != spot { usleep(20_000) }
        }
        return isParked
    }
}

/// Info about the running daemon's display, validated against the live display list.
func liveDaemon() -> DaemonInfo? {
    guard var info = readJSON(Paths.daemon, DaemonInfo.self), info.matchesProcess else { return nil }
    guard isOurDisplay(info.displayID), CGDisplayIsActive(info.displayID) != 0 else { return nil }
    let b = CGDisplayBounds(info.displayID)
    info.x = b.origin.x; info.y = b.origin.y; info.width = b.width; info.height = b.height
    return info
}
