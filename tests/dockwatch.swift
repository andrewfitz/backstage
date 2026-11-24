// Dock watcher for tests/dock.sh.
//   dockwatch watch <title>... --stop FILE [--max S]
//       Samples the Dock's items (through its accessibility tree) every ~10 ms until FILE exists,
//       and reports every time an item whose title contains one of the titles appears.
//       Prints "appeared <title> at <ms>" per appearance, then "shows=N samples=N maxgap=Nms".
//   dockwatch type <pid>
//       Prints the app's LaunchServices application type (Foreground, UIElement, …).
//   dockwatch has <title>
//       Prints "yes" if the Dock has an item whose title contains <title>, else "no".
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    return (v as? [AXUIElement]) ?? []
}
func title(_ e: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &v)
    return (v as? String) ?? ""
}

guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    print("no Dock process"); exit(2)
}
let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
AXUIElementSetMessagingTimeout(dockAX, 0.5)
var lists: [AXUIElement] = []
var counts: [Int] = []
var titles: [String] = []
var lastFull = 0.0
func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
/// Cheap sample: one count per item list; titles re-read when a count changes or every 250 ms.
func dockTitles() -> [String] {
    if lists.isEmpty { lists = children(dockAX) }
    let c = lists.map { l -> Int in var n: CFIndex = 0; AXUIElementGetAttributeValueCount(l, kAXChildrenAttribute as CFString, &n); return n }
    if c != counts || now() - lastFull > 250 {
        counts = c; lastFull = now()
        titles = lists.flatMap { children($0).map(title) }
    }
    return titles
}

switch args.first {
case "watch":
    guard let s = args.firstIndex(of: "--stop"), s + 1 < args.count else { print("usage"); exit(2) }
    let stop = args[s + 1]
    let wanted = Array(args[1..<s])
    let maxSecs = args.firstIndex(of: "--max").flatMap { Double(args[$0 + 1]) } ?? 600
    // No App Nap or timer coalescing: they stretch the 10 ms sampling interval to a second.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "sampling the Dock")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let start = now()
    var present = Set<String>(), shows = 0, samples = 0, last = 0.0, maxGap = 0.0
    // Items already in the Dock (e.g. a pinned app with the same name) don't count.
    let initialTitles = dockTitles()
    guard counts.contains(where: { $0 > 0 }) else {
        print("could not read any Dock items through Accessibility"); exit(2)
    }
    let preexisting = Set(initialTitles.filter { t in wanted.contains { t.localizedCaseInsensitiveContains($0) } })
    if !preexisting.isEmpty { print("preexisting \(preexisting.sorted())") }
    print("watching")
    while !FileManager.default.fileExists(atPath: stop) && now() - start < maxSecs * 1000 {
        let t = now()
        if last > 0 { maxGap = max(maxGap, t - last); if t - last > 200 { print("gap \(Int(t - last))ms at \(Int(t - start))ms") } }
        last = t; samples += 1
        let hits = Set(dockTitles().filter { t in wanted.contains { t.localizedCaseInsensitiveContains($0) } }).subtracting(preexisting)
        for h in hits.subtracting(present) { shows += 1; print("appeared \(h) at \(Int(t - start))ms") }
        for h in present.subtracting(hits) { print("gone \(h) at \(Int(t - start))ms") }
        present = hits
        usleep(10_000)
    }
    guard FileManager.default.fileExists(atPath: stop) else {
        print("timed out before the Dock test finished"); exit(2)
    }
    print("shows=\(shows) samples=\(samples) maxgap=\(Int(maxGap))ms")
case "type":
    let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)
    typealias ASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    typealias Item = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    let asn = unsafeBitCast(dlsym(h, "_LSASNCreateWithPid")!, to: ASN.self)
    let item = unsafeBitCast(dlsym(h, "_LSCopyApplicationInformationItem")!, to: Item.self)
    guard let pid = pid_t(args[1]), let a = asn(nil, pid)?.takeRetainedValue() else { print("none"); exit(0) }
    print((item(-2, a, "ApplicationType" as CFString)?.takeRetainedValue() as? String) ?? "none")
case "has":
    print(dockTitles().contains { $0.localizedCaseInsensitiveContains(args[1]) } ? "yes" : "no")
default:
    print("usage: dockwatch watch <title>... --stop FILE [--max S] | type <pid> | has <title>")
    exit(2)
}
