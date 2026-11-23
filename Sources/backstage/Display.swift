import Foundation
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

func isOurDisplay(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == kVendor && CGDisplayModelNumber(id) == kProduct
}

/// Bounds (global, top-left origin) of every display the user can actually see.
func userDisplayBounds() -> [CGRect] {
    activeDisplays()
        .filter { !isOurDisplay($0) && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        .map { CGDisplayBounds($0) }
}

func userDisplaysUnion() -> CGRect {
    userDisplayBounds().reduce(CGRect.null) { $0.union($1) }
}

/// Holds the private CGVirtualDisplay alive. Dropping it removes the display.
final class AgentDisplay {
    let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }
    var bounds: CGRect { CGDisplayBounds(id) }

    init(width: UInt32, height: UInt32) throws {
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue.main
        d.name = "Backstage (agent display)"
        d.maxPixelsWide = width
        d.maxPixelsHigh = height
        // ~100 dpi so apps pick 1x rendering
        d.sizeInMillimeters = CGSize(width: Double(width) * 0.254, height: Double(height) * 0.254)
        d.vendorID = kVendor
        d.productID = kProduct
        d.serialNum = 1
        d.terminationHandler = { _, _ in eprint("virtual display terminated by system") }
        guard let vd = CGVirtualDisplay(descriptor: d) else { throw CLIError("CGVirtualDisplay init failed") }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 0
        s.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 30)]
        guard vd.apply(s) else { throw CLIError("CGVirtualDisplay applySettings failed") }
        display = vd
    }

    /// Park the display diagonally off the bottom-right corner of the user's desktop so that
    /// it only touches at a single corner point: the cursor essentially can't wander onto it
    /// (and the daemon warps it back if it does).
    @discardableResult
    func park() -> Bool {
        let u = userDisplaysUnion()
        guard !u.isNull, let x = Int32(exactly: u.maxX), let y = Int32(exactly: u.maxY) else { return false }
        if bounds.origin == CGPoint(x: Int(x), y: Int(y)) { return true }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        guard CGConfigureDisplayOrigin(cfg, id, x, y) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
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
