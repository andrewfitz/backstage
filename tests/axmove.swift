// Test helper for tests/multi.sh: moves the first window of <pid> so its top-left is at global
// point <x>,<y> (through Accessibility, as a user or the app itself could), then prints the
// window's frame. Only ever pointed at backstage displays: never the user's screens.
// usage: axmove <pid> <x> <y>
//        axmove --frames <pid>   prints "x y w h" (global points) for each on-screen window of <pid>
//        axmove --position <pid> prints "x y", the first window's top-left (Accessibility; hidden apps too)
import ApplicationServices
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--frames", args.count == 2, let pid = Int32(args[1]) {
    for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
              let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d) else { continue }
        print(Int(r.minX), Int(r.minY), Int(r.width), Int(r.height))
    }
    exit(0)
}
if args.first == "--position", args.count == 2, let pid = Int32(args[1]) {
    // The first window's top-left through Accessibility: works while the app is hidden.
    var value: CFTypeRef?, pos: CFTypeRef?
    var p = CGPoint.zero
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
          let w = (value as? [AXUIElement])?.first,
          AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
          AXValueGetValue(pos as! AXValue, .cgPoint, &p) else { print("no window"); exit(1) }
    print(Int(p.x), Int(p.y))
    exit(0)
}
guard args.count == 3, let pid = Int32(args[0]), let x = Double(args[1]), let y = Double(args[2]) else {
    print("usage: axmove <pid> <x> <y> | axmove --frames <pid>"); exit(2)
}
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let window = (value as? [AXUIElement])?.first else { print("no window"); exit(1) }
var point = CGPoint(x: x, y: y)
let rc = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
print(rc == .success ? "moved" : "failed \(rc.rawValue)")
exit(rc == .success ? 0 : 1)
