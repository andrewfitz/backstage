import Foundation
import CoreGraphics
import os

/// Keeps the user's keyboard and mouse input and the agents' input apart.
///
/// An app tracking a menu (a context menu from `click --right`, a menu bar menu, a pop-up
/// button's menu) takes the WindowServer's keyboard focus for as long as the menu is open, even
/// when the app is in the background: that is how macOS lets you work a background app's context
/// menu from the keyboard. For an agent app, that means the user's typing would go into the
/// hidden app. Nothing outside the app can stop it from taking focus, so the daemon filters
/// input instead: an event tap that sees every key, click and scroll after the WindowServer has
/// picked its target process.
///  - Events backstage posts are tagged (`InputTag.agent` in the source user-data field) and pass.
///  - An untagged event headed for a managed app is someone else's input: the user's. Keys from
///    the HID system (keyboards, and remote-control tools such as Parsec, which post HID events)
///    are handed to the user's frontmost app instead; everything else is dropped.
/// The tap runs on its own thread, so a busy daemon main loop (AX calls can take seconds) never
/// delays the user's input. If macOS disables the tap (timeout), it is re-enabled at once.
enum InputTag {
    /// backstage's own input for a managed app (CLI commands, launch priming).
    static let agent: Int64 = 0x6273_7467_0001
    /// The user's input, taken from a managed app and handed to the user's app by the guard.
    static let redirected: Int64 = 0x6273_7467_0002
}

extension CGEvent {
    /// Post straight to one process, tagged as backstage's input so the input guard lets it through.
    func postTagged(to pid: pid_t) {
        setIntegerValueField(.eventSourceUserData, value: InputTag.agent)
        postToPid(pid)
    }
}

enum GuardVerdict: String { case pass, redirect, drop }

/// What the guard does with one event. Pure, so `backstage __guard-selftest` can check it.
func classifyInput(type: CGEventType, target: pid_t, tag: Int64, hidState: Bool, managed: Set<pid_t>) -> GuardVerdict {
    guard managed.contains(target) else { return .pass }
    if tag == InputTag.agent { return .pass }
    let key = type == .keyDown || type == .keyUp || type == .flagsChanged
    return key && hidState && tag != InputTag.redirected ? .redirect : .drop
}

let guardedEventTypes: [CGEventType] = [
    .keyDown, .keyUp, .flagsChanged,
    .leftMouseDown, .leftMouseUp, .leftMouseDragged,
    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
    .otherMouseDown, .otherMouseUp, .otherMouseDragged,
    .scrollWheel,
]

final class InputGuard {
    struct Stats: Equatable {
        var events = 0, redirected = 0, dropped = 0, reenabled = 0, lost = 0
        var maxMicros = 0.0, totalMicros = 0.0, over1ms = 0
        var lastTarget: pid_t = 0
    }

    private var lock = os_unfair_lock()
    private var managed: Set<pid_t> = []
    private var userPid: pid_t = 0
    private var stats = Stats()
    private var tap: CFMachPort?
    private var logged = Stats()

    /// Install the tap on a dedicated thread. False if macOS refused it (no Accessibility trust).
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [self] in
            let mask = guardedEventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            guard let port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: inputGuardCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal(); return
            }
            tap = port
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ok = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "backstage input guard"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return ok
    }

    func update(managed m: Set<pid_t>, userPid u: pid_t) {
        os_unfair_lock_lock(&lock); managed = m; userPid = u; os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> Stats {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return stats
    }

    /// Called from the daemon's tick: one log line whenever the guard acted since the last one.
    func logActivity(_ log: (String) -> Void, force: Bool = false) {
        let s = snapshot()
        guard force || s.redirected != logged.redirected || s.dropped != logged.dropped || s.reenabled != logged.reenabled || s.lost != logged.lost else { return }
        log(String(format: "input guard: %d redirected to the user's app, %d dropped, %d unredirectable, %d re-enables (last target pid %d; "
                   + "%d events seen, %.0fµs average, %d over 1ms, slowest %.0fµs)",
                   s.redirected, s.dropped, s.lost, s.reenabled, s.lastTarget, s.events, s.totalMicros / Double(max(1, s.events)), s.over1ms, s.maxMicros))
        logged = s
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            os_unfair_lock_lock(&lock); stats.reenabled += 1; os_unfair_lock_unlock(&lock)
            return Unmanaged.passUnretained(event)
        }
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let target = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let hid = event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        os_unfair_lock_lock(&lock)
        let verdict = classifyInput(type: type, target: target, tag: tag, hidState: hid, managed: managed)
        let user = userPid
        os_unfair_lock_unlock(&lock)
        var result: Unmanaged<CGEvent>? = Unmanaged.passUnretained(event)
        var lost = false
        switch verdict {
        case .pass: break
        case .drop: result = nil
        case .redirect:
            result = nil
            // The keystroke was meant for the user's own app: give it to that app, tagged so the
            // guard knows it (it can never bounce back into a managed app).
            if user > 0, let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: InputTag.redirected)
                copy.postToPid(user)
            } else {
                lost = true
            }
        }
        let micros = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1000
        os_unfair_lock_lock(&lock)
        stats.events += 1
        stats.maxMicros = max(stats.maxMicros, micros)
        stats.totalMicros += micros
        if micros > 1000 { stats.over1ms += 1 }
        if verdict != .pass { stats.lastTarget = target }
        if verdict == .redirect { if lost { stats.lost += 1 } else { stats.redirected += 1 } }
        if verdict == .drop { stats.dropped += 1 }
        os_unfair_lock_unlock(&lock)
        return result
    }
}

private func inputGuardCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputGuard>.fromOpaque(info).takeUnretainedValue().handle(type, event)
}

/// `backstage __guard-selftest`: run the classifier over constructed events (never posted).
func guardSelfTest() -> [String: Any] {
    let agentApp: pid_t = 4242, userApp: pid_t = 777
    let managed: Set<pid_t> = [agentApp]
    let cases: [(String, CGEventType, pid_t, Int64, Bool, GuardVerdict)] = [
        ("user key into agent app is redirected", .keyDown, agentApp, 0, true, .redirect),
        ("user key-up into agent app is redirected", .keyUp, agentApp, 0, true, .redirect),
        ("user modifier into agent app is redirected", .flagsChanged, agentApp, 0, true, .redirect),
        ("user click into agent app is dropped", .leftMouseDown, agentApp, 0, true, .drop),
        ("user scroll into agent app is dropped", .scrollWheel, agentApp, 0, true, .drop),
        ("untagged non-HID key into agent app is dropped", .keyDown, agentApp, 0, false, .drop),
        ("redirected key never re-enters an agent app", .keyDown, agentApp, InputTag.redirected, true, .drop),
        ("backstage key into agent app passes", .keyDown, agentApp, InputTag.agent, false, .pass),
        ("backstage click into agent app passes", .rightMouseDown, agentApp, InputTag.agent, false, .pass),
        ("user key into user app passes", .keyDown, userApp, 0, true, .pass),
        ("user click into user app passes", .leftMouseDown, userApp, 0, true, .pass),
        ("redirected key into user app passes", .keyDown, userApp, InputTag.redirected, true, .pass),
    ]
    var failures: [String] = []
    for (name, type, target, tag, hid, want) in cases {
        // Read the fields back from a real CGEvent, as the tap does.
        let e = type == .scrollWheel ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
            : [.keyDown, .keyUp, .flagsChanged].contains(type) ? CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: type != .keyUp)
            : CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: type == .rightMouseDown ? .right : .left)
        guard let e else { failures.append("\(name): could not build event"); continue }
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        let got = classifyInput(type: type, target: target, tag: e.getIntegerValueField(.eventSourceUserData), hidState: hid, managed: managed)
        if got != want { failures.append("\(name): got \(got.rawValue), want \(want.rawValue)") }
    }
    return ["ok": failures.isEmpty, "cases": cases.count, "failures": failures]
}
