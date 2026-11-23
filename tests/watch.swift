// Non-interference watchdog. Samples the window list as fast as it can (reports the achieved
// interval) for N seconds and reports any moment where
//  - a window owned by a process with the given bundle ID is on-screen on a user display, or
//  - that process is frontmost, or
//  - the cursor is on a non-user (virtual) display.
// usage: watch <bundle-id> <seconds> [stop-file]
import Cocoa

let bundleID = CommandLine.arguments[1]
let secs = Double(CommandLine.arguments[2])!
func userDisplays() -> [CGRect] {
    var n: UInt32 = 0; var ids = [CGDirectDisplayID](repeating: 0, count: 32); CGGetActiveDisplayList(32, &ids, &n)
    return ids[0..<Int(n)].filter { CGDisplayVendorNumber($0) != 0xB57A }.map { CGDisplayBounds($0) }
}
var violations: [String: Int] = [:]
struct Exposure {
    let title: String
    let first: Double
    var last: Double
    var samples: Int
}
var active: [CGWindowID: Exposure] = [:]
var completed: [Exposure] = []
let t0 = Date()
var samples = 0
let end = Date().addingTimeInterval(secs)
let frontAtStart = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
let stopFile = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
while Date() < end && !(stopFile.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
    samples += 1
    let screens = userDisplays()
    guard !screens.isEmpty,
          let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        print("watch: failed to enumerate user displays or windows")
        exit(1)
    }
    let now = ProcessInfo.processInfo.systemUptime
    var exposed: Set<CGWindowID> = []
    for w in wins {
        guard w[kCGWindowOwnerName as String] as? String == "BackstageTestApp",
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID else { continue }
        guard let bd = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: bd) else { continue }
        if (w[kCGWindowLayer as String] as? Int ?? 0) >= 1000 { continue }
        if screens.contains(where: { $0.intersects(b) }), let id = w[kCGWindowNumber as String] as? CGWindowID {
            exposed.insert(id)
            var episode = active[id] ?? Exposure(title: w[kCGWindowName as String] as? String ?? "?", first: now, last: now, samples: 0)
            episode.last = now
            episode.samples += 1
            active[id] = episode
        }
    }
    for id in active.keys where !exposed.contains(id) {
        if let ended = active.removeValue(forKey: id) { completed.append(ended) }
    }
    // frontmostApplication is KVO-cached; use the window server's view instead (slow: every 20th sample).
    if samples % 20 == 0, let pid = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier,
       NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID {
        violations["test app became frontmost", default: 0] += 1
    }
    if let loc = CGEvent(source: nil)?.location, !screens.contains(where: { $0.contains(loc) }) {
        violations["cursor off user displays at \(loc)", default: 0] += 1
    }
    if samples % 20 == 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
}
let frontAtEnd = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
print("watch: \(samples) samples (\(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000 / Double(samples)))ms each), front start=\(frontAtStart) end=\(frontAtEnd)")
// A window an app opens *later* can be on screen for a moment before the AX observer moves it.
// Tolerate under one 60Hz frame (16ms) per window; anything longer is a failure.
for episode in completed + Array(active.values) {
    let milliseconds = (episode.last - episode.first) * 1000
    let detail = "window '\(episode.title)' on a user screen for \(episode.samples) sample(s), \(String(format: "%.1f", milliseconds))ms from first to last observation"
    if milliseconds > 16 { violations[detail, default: 0] += 1 }
    else { print("watch: note: \(detail)") }
}
if samples == 0 || (stopFile.map { !FileManager.default.fileExists(atPath: $0) } ?? false) {
    print("watch: no samples or deadline reached before teardown")
    exit(1)
}
if violations.isEmpty { print("watch: PASS — no interference observed") }
else { for (k, v) in violations { print("watch: VIOLATION x\(v): \(k)") }; exit(1) }
