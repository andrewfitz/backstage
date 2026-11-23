// Window-list queries for tests/concurrency.sh.
// usage: zorder <pid> [<pid>…]   prints the PIDs front to back, by the stacking order of their
//                                frontmost normal window (PIDs with no on-screen window are left out)
//        zorder --menus <pid>    prints how many on-screen menu windows (popup menu layer) the PID has
//        zorder --display        lists the normal windows that intersect the agent display
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--display" {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    CGGetActiveDisplayList(32, &ids, &count)
    guard let agent = ids.prefix(Int(count)).first(where: { CGDisplayVendorNumber($0) == 0xB57A }) else { print("no agent display"); exit(1) }
    let bounds = CGDisplayBounds(agent)
    for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
        guard (w[kCGWindowLayer as String] as? Int) == 0, let d = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: d), r.intersects(bounds) else { continue }
        print("\(w[kCGWindowOwnerName as String] ?? "?") pid \(w[kCGWindowOwnerPID as String] ?? "?"): \(r.offsetBy(dx: -bounds.minX, dy: -bounds.minY))")
    }
    exit(0)
}
let menus = args.first == "--menus"
if menus { args.removeFirst() }
let wanted = args.compactMap { Int32($0) }
guard !wanted.isEmpty,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("usage: zorder [--menus] <pid> [<pid>…]")
    exit(2)
}
if menus {
    let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
    print(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == wanted[0] && ($0[kCGWindowLayer as String] as? Int) == menuLayer }.count)
    exit(0)
}
var order: [Int32] = []
for w in windows {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int32, wanted.contains(pid), !order.contains(pid),
          (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    order.append(pid)
}
print(order.map(String.init).joined(separator: " "))
