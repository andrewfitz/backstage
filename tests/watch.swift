// Non-interference watchdog. Samples the window list as fast as it can (reports the achieved
// interval) for N seconds and reports any moment where
//  - a window owned by a process with the given bundle ID is on-screen on a user display, or
//  - that process is frontmost, or
//  - the cursor is on a non-user (virtual) display, or
//  - the Dock is not on a user display (macOS moves it to a display arranged below its own, or
//    to one whose bottom edge the cursor lingers at), or
//  - input that backstage didn't send (the user's typing, clicks, scrolls) reached that process,
//    or input backstage sent reached the user's frontmost app. A listen-only event tap sees every
//    key, click and scroll after the WindowServer has picked its target process; backstage tags
//    its own events (kCGEventSourceUserData), so nothing here depends on someone typing: any
//    untagged event a test posts to the test app, or any key the user types while a test app holds
//    the keyboard focus, shows up. It also polls which process holds the keyboard focus (an open
//    menu takes it, even in a background app) and reports how long the test app held it.
// usage: watch <bundle-id> <seconds> [stop-file [ready-file]]
import Cocoa
import os

let args = CommandLine.arguments
guard (3...5).contains(args.count), let secs = Double(args[2]), secs.isFinite, secs > 0 else {
    print("usage: watch <bundle-id> <seconds> [stop-file [ready-file]]")
    exit(2)
}
let bundleID = args[1]
func displays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0; var ids = [CGDirectDisplayID](repeating: 0, count: 32); CGGetActiveDisplayList(32, &ids, &n)
    return Array(ids[0..<Int(n)])
}
func userDisplays() -> [CGRect] { displays().filter { CGDisplayVendorNumber($0) != 0xB57A }.map { CGDisplayBounds($0) } }
func agentDisplays() -> [(CGDirectDisplayID, CGRect)] { displays().filter { CGDisplayVendorNumber($0) == 0xB57A }.map { ($0, CGDisplayBounds($0)) } }
// The Dock's window is as large as the display the Dock is on.
let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { let i = a.intersection(b); return !i.isNull && i.width > 0 && i.height > 0 }
var violations: [String: Int] = [:]

// Tags backstage puts in kCGEventSourceUserData (Sources/backstage/InputGuard.swift).
let agentTag: Int64 = 0x6273_7467_0001, redirectedTag: Int64 = 0x6273_7467_0002
var tapLock = os_unfair_lock()
var testPids: Set<pid_t> = []
var userFront: pid_t = 0
var tapViolations: [String: Int] = [:]
var tapNotes: [String: Int] = [:]
@Sendable func withTapLock<T>(_ body: () -> T) -> T { os_unfair_lock_lock(&tapLock); defer { os_unfair_lock_unlock(&tapLock) }; return body() }
func refreshPids() {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
    let front = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier ?? 0
    withTapLock { testPids = pids; if !pids.contains(front) { userFront = front } }
}
refreshPids()
var watchTap: CFMachPort?

enum WatchCallbacks {
    static func observeTapEvent(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent> {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            withTapLock { tapViolations["watch's event tap was disabled by macOS (\(type.rawValue)); input observations were interrupted", default: 0] += 1 }
            if let tap = watchTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        let target = pid_t(truncatingIfNeeded: e.getIntegerValueField(.eventTargetUnixProcessID))
        let source = e.getIntegerValueField(.eventSourceUnixProcessID), tag = e.getIntegerValueField(.eventSourceUserData)
        withTapLock {
            if testPids.contains(target) && tag != agentTag {
                tapViolations["input backstage didn't send (event type \(type.rawValue) from pid \(source)) reached the test app", default: 0] += 1
            } else if tag == agentTag && target == userFront && target != 0 {
                tapViolations["backstage input (event type \(type.rawValue)) reached the user's frontmost app (pid \(target))", default: 0] += 1
            } else if tag == redirectedTag {
                tapNotes["user input the daemon's input guard handed back to the user's app", default: 0] += 1
            }
        }
        return Unmanaged.passUnretained(e)
    }
}
let tapTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                               .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
do {
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread {
        // Listen-only, appended last: it sees what is left after the daemon's input guard.
        watchTap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                     eventsOfInterest: tapTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) },
                                     callback: { _, type, event, _ in WatchCallbacks.observeTapEvent(type, event) },
                                     userInfo: nil)
        if let tap = watchTap { CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
        ready.signal()
        if watchTap != nil { CFRunLoopRun() }
    }
    thread.start()
    ready.wait()
    guard watchTap != nil else { print("watch: could not install the input event tap (Accessibility / Input Monitoring?)"); exit(1) }
}

// Which process holds the WindowServer's keyboard focus (SkyLight, private). Not the frontmost app:
// an open menu takes the focus without activating its app.
typealias KeyFocusFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt64>) -> Int32
typealias PSNToPIDFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> Int32
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let keyFocusFn = dlsym(skyLight, "SLPSGetKeyFocusProcess").map { unsafeBitCast($0, to: KeyFocusFn.self) }
// The query needs this process's WindowServer connection, which nothing else here opens.
_ = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self)() }
let psnToPID = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW), "GetProcessPID")
    .map { unsafeBitCast($0, to: PSNToPIDFn.self) }
func keyFocusPid() -> pid_t? {
    guard let keyFocusFn, let psnToPID else { return nil }
    var psn = ProcessSerialNumber(), extra: UInt64 = 0, pid: pid_t = 0
    guard keyFocusFn(&psn, &extra) == 0, psnToPID(&psn, &pid) == 0 else { return nil }
    return pid
}
if keyFocusPid() == nil { print("watch: cannot read the keyboard focus process"); exit(1) }
var focusSince: Double?
var focusEpisodes: [Double] = []
struct Exposure {
    let title: String
    let first: Double
    var last: Double
    var samples: Int
}
var active: [CGWindowID: Exposure] = [:]
var completed: [Exposure] = []
let t0 = ProcessInfo.processInfo.systemUptime
var samples = 0
let end = t0 + secs
let frontAtStart = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
let stopFile = args.count > 3 ? args[3] : nil
let readyFile = args.count > 4 ? args[4] : nil
while ProcessInfo.processInfo.systemUptime < end && !(stopFile.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
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
    // CGRect.contains leaves out maxX/maxY, as the cursor does: on a 1080-point-high display it
    // goes down to y 1079.x, so y == 1080 is the next display down (an agent display parked
    // along the user's bottom edge instead of at the corner).
    if let loc = CGEvent(source: nil)?.location, !screens.contains(where: { $0.contains(loc) }) {
        let on = agentDisplays().first { $0.1.contains(loc) }.map { "on backstage display \($0.0) \($0.1)" } ?? "off every display"
        violations["cursor off user displays at \(loc), \(on)", default: 0] += 1
    }
    if samples % 10 == 0, let dockPid,
       let dock = wins.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == dockPid && ($0[kCGWindowLayer as String] as? Int) == dockLevel }),
       let bd = dock[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: bd) {
        if let agent = agentDisplays().first(where: { overlaps($0.1, b) }) {
            violations["the Dock is on backstage display \(agent.0) \(agent.1)", default: 0] += 1
        } else if !screens.contains(where: { overlaps($0, b) }) {
            violations["the Dock is off the user's displays at \(b)", default: 0] += 1
        }
    }
    if let pid = keyFocusPid(), withTapLock({ testPids.contains(pid) }) {
        if focusSince == nil { focusSince = now }
    } else if let since = focusSince {
        focusEpisodes.append(now - since); focusSince = nil
    }
    if samples % 20 == 0 { refreshPids(); RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
    if samples == 1, let readyFile,
       !FileManager.default.createFile(atPath: readyFile, contents: nil) {
        print("watch: could not create ready file")
        exit(1)
    }
}
let frontAtEnd = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
print("watch: \(samples) samples (\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - t0) * 1000 / Double(max(1, samples))))ms each), front start=\(frontAtStart) end=\(frontAtEnd)")
// A window an app opens *later* can be on screen for a moment before the AX observer moves it.
// Tolerate under one 60Hz frame (16ms) per window; anything longer is a failure.
if let since = focusSince { focusEpisodes.append(ProcessInfo.processInfo.systemUptime - since) }
if !focusEpisodes.isEmpty {
    // Expected while a test app's menu is open: the input guard keeps the user's input out (the
    // tap checks above). A focus held much longer than any test's menu means one was left open.
    print("watch: note: keyboard focus at the test app \(focusEpisodes.count) time(s), \(String(format: "%.0f", focusEpisodes.reduce(0, +) * 1000))ms in all, longest \(String(format: "%.0f", (focusEpisodes.max() ?? 0) * 1000))ms")
    for e in focusEpisodes where e > 15 { violations["keyboard focus held by the test app for \(String(format: "%.1f", e))s (a menu left open?)", default: 0] += 1 }
}
withTapLock {
    for (k, v) in tapViolations { violations[k, default: 0] += v }
    for (k, v) in tapNotes { print("watch: note: \(k) x\(v)") }
}
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
