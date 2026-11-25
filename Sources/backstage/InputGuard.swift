import Foundation
import CoreGraphics
import Security
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
///  - Except an untagged event posted by a computer-use agent's per-app input helper (Claude
///    desktop's background `app_*` tools, Codex computer use): that's an agent driving the app it
///    picked, so it passes (after verifying its code signature).
///  - Events headed for any app backstage doesn't manage are never touched.
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
enum ComputerUseOrigin { case unrelated, verifiedHelper, rejectedHelper }

/// Classify one event. Source inspection runs lazily for untagged input headed to managed apps.
func classifyInput(type: CGEventType, target: pid_t, tag: Int64, hidState: Bool, managed: Set<pid_t>,
                   fromManagedApp: Bool = false,
                   computerUseOrigin: @autoclosure () -> ComputerUseOrigin = .unrelated) -> GuardVerdict {
    guard managed.contains(target) else { return .pass }
    if tag == InputTag.agent { return .pass }
    if fromManagedApp || tag == InputTag.redirected { return .drop }
    switch computerUseOrigin() {
    case .verifiedHelper: return .pass
    case .rejectedHelper: return .drop
    case .unrelated: break
    }
    let key = type == .keyDown || type == .keyUp || type == .flagsChanged
    return key && hidState ? .redirect : .drop
}

private struct ComputerUseHelper {
    let suffix: String
    let requirement: SecRequirement?

    init(suffix: String, identifier: String, team: String) {
        self.suffix = suffix
        let expression = """
            identifier "\(identifier)" and anchor apple generic
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
            and certificate leaf[subject.OU] = "\(team)"
            """
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        self.requirement = status == errSecSuccess ? requirement : nil
    }
}

private let computerUseHelpers = [
    ComputerUseHelper(suffix: "/Contents/Helpers/app-cu-helper", identifier: "app-cu-helper", team: "Q6L2SF6YDW"),
    ComputerUseHelper(suffix: "/Contents/MacOS/SkyComputerUseService", identifier: "com.openai.sky.CUAService", team: "2DC432GLL2"),
]

/// Use the path to select a signing requirement, then validate the live process against it.
/// Process birth alone cannot identify the running code across exec.
func computerUseOrigin(_ pid: pid_t) -> ComputerUseOrigin {
    guard pid > 0 else { return .unrelated }
    let candidate = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4 * Int(MAXPATHLEN)) { buf -> ComputerUseHelper? in
        guard let path = buf.baseAddress, proc_pidpath(pid, path, UInt32(buf.count)) > 0 else { return nil }
        let executable = String(cString: path)
        return computerUseHelpers.first { executable.hasSuffix($0.suffix) }
    }
    guard let candidate else { return .unrelated }
    guard let requirement = candidate.requirement, let birth = processBirth(pid) else { return .rejectedHelper }
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
          processBirth(pid) == birth else { return .rejectedHelper }
    return .verifiedHelper
}

let guardedEventTypes: [CGEventType] = [
    .keyDown, .keyUp, .flagsChanged,
    .leftMouseDown, .leftMouseUp, .leftMouseDragged,
    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
    .otherMouseDown, .otherMouseUp, .otherMouseDragged,
    .scrollWheel,
]

private final class InputGuardTap {
    unowned let guarder: InputGuard
    let target: pid_t?
    let birth: UInt64?
    var port: CFMachPort?

    init(guarder: InputGuard, target: pid_t?, birth: UInt64?) {
        self.guarder = guarder
        self.target = target
        self.birth = birth
    }
}

final class InputGuard {
    struct Stats: Equatable {
        var events = 0, redirected = 0, dropped = 0, reenabled = 0, lost = 0, computerUse = 0
        var maxMicros = 0.0, totalMicros = 0.0, over1ms = 0
        var lastTarget: pid_t = 0
    }

    private var lock = os_unfair_lock()
    private var managed: Set<pid_t> = []
    private var births: [pid_t: UInt64] = [:]
    private var userPid: pid_t = 0
    private var userBirth: UInt64?
    private var stats = Stats()
    private var runLoop: CFRunLoop?
    // Only the tap thread creates, uses, or removes these callback contexts.
    private var processTaps: [pid_t: InputGuardTap] = [:]
    private var logged = Stats()

    /// Install the tap on a dedicated thread. False if macOS refused it (no Accessibility trust).
    func start() -> Bool {
        _ = computerUseHelpers // Compile signing requirements before the first event callback.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            guard let sessionTap = installTap(on: loop, target: nil), let port = sessionTap.port else {
                ready.signal()
                return
            }
            runLoop = loop
            ready.signal()
            // Keep callback context alive until the port has been invalidated.
            withExtendedLifetime(sessionTap) {
                CFRunLoopRun()
                CFMachPortInvalidate(port)
            }
        }
        thread.name = "backstage input guard"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return runLoop != nil
    }

    private func installTap(on loop: CFRunLoop, target: pid_t?, birth: UInt64? = nil) -> InputGuardTap? {
        let context = InputGuardTap(guarder: self, target: target, birth: birth)
        let info = Unmanaged.passUnretained(context).toOpaque()
        let mask = guardedEventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let port: CFMachPort?
        if let target {
            port = CGEvent.tapCreateForPid(pid: target, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: inputGuardCallback, userInfo: info)
        } else {
            port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: inputGuardCallback, userInfo: info)
        }
        guard let port else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        context.port = port
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return context
    }

    func updateUser(_ user: pid_t) {
        let birth = processBirth(user)
        os_unfair_lock_lock(&lock)
        userPid = user
        userBirth = birth
        os_unfair_lock_unlock(&lock)
    }

    func update(managed m: Set<pid_t>, births b: [pid_t: UInt64]) {
        os_unfair_lock_lock(&lock)
        let changed = births != b
        managed = m
        births = b
        os_unfair_lock_unlock(&lock)
        guard changed, let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            updateProcessTaps(on: runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func updateProcessTaps(on loop: CFRunLoop) {
        os_unfair_lock_lock(&lock)
        let targets = births
        os_unfair_lock_unlock(&lock)
        for (pid, tap) in processTaps where targets[pid] != tap.birth {
            if let port = tap.port { CFMachPortInvalidate(port) }
            processTaps.removeValue(forKey: pid)
        }
        // Direct posts can reach app-specific taps without appearing at the annotated session
        // tap. The destination is known here even when the event's target field is missing.
        for (pid, birth) in targets where processTaps[pid] == nil && processBirth(pid) == birth {
            processTaps[pid] = installTap(on: loop, target: pid, birth: birth)
        }
    }

    func snapshot() -> Stats {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return stats
    }

    /// Called from the daemon's tick: one log line whenever the guard acted since the last one.
    func logActivity(_ log: (String) -> Void, force: Bool = false) {
        let s = snapshot()
        guard force || s.redirected != logged.redirected || s.dropped != logged.dropped || s.reenabled != logged.reenabled || s.lost != logged.lost
                || s.computerUse != logged.computerUse else { return }
        log(String(format: "input guard: %d redirected to the user's app, %d dropped, %d unredirectable, %d re-enables, %d from computer use let through "
                   + "(last target pid %d; %d tap callbacks, %.0fµs average, %d over 1ms, slowest %.0fµs)",
                   s.redirected, s.dropped, s.lost, s.reenabled, s.computerUse, s.lastTarget, s.events, s.totalMicros / Double(max(1, s.events)), s.over1ms, s.maxMicros))
        logged = s
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent, from tap: InputGuardTap) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
            os_unfair_lock_lock(&lock); stats.reenabled += 1; os_unfair_lock_unlock(&lock)
            return Unmanaged.passUnretained(event)
        }
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let target = tap.target ?? pid_t(exactly: event.getIntegerValueField(.eventTargetUnixProcessID)) ?? 0
        let source = pid_t(exactly: event.getIntegerValueField(.eventSourceUnixProcessID)) ?? 0
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let hid = event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        os_unfair_lock_lock(&lock)
        let managedNow = managed, birth = births[target], user = userPid, userStart = userBirth
        os_unfair_lock_unlock(&lock)
        // A tap queued for removal must not act on events for a handed-off app or reused PID.
        if let pinned = tap.birth, pinned != birth || processBirth(target) != pinned {
            return Unmanaged.passUnretained(event)
        }
        // The poster's executable is looked up only for untagged events headed for a managed app.
        var origin = ComputerUseOrigin.unrelated
        let verdict = classifyInput(type: type, target: target, tag: tag, hidState: hid, managed: managedNow,
                                    fromManagedApp: managedNow.contains(source),
                                    computerUseOrigin: { () -> ComputerUseOrigin in
                                        origin = computerUseOrigin(source)
                                        return origin
                                    }())
        var result: Unmanaged<CGEvent>? = Unmanaged.passUnretained(event)
        var lost = false
        switch verdict {
        case .pass: break
        case .drop: result = nil
        case .redirect:
            result = nil
            // The keystroke was meant for the user's own app: give it to that app, tagged so the
            // guard knows it (it can never bounce back into a managed app).
            if let birth, tap.birth != nil || processBirth(target) == birth,
               let userStart, !managedNow.contains(user), processBirth(user) == userStart, let copy = event.copy() {
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
        // A drop or redirect ends delivery; a trusted pass may reach both taps.
        let countedComputerUse = origin == .verifiedHelper && (tap.target != nil || processTaps[target] == nil)
        if verdict != .pass || countedComputerUse { stats.lastTarget = target }
        if countedComputerUse { stats.computerUse += 1 }
        if verdict == .redirect { if lost { stats.lost += 1 } else { stats.redirected += 1 } }
        if verdict == .drop { stats.dropped += 1 }
        os_unfair_lock_unlock(&lock)
        return result
    }
}

private func inputGuardCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return autoreleasepool {
        let tap = Unmanaged<InputGuardTap>.fromOpaque(info).takeUnretainedValue()
        return tap.guarder.handle(type, event, from: tap)
    }
}

/// `backstage __guard-selftest`: run the classifier over constructed events (never posted).
func guardSelfTest(rejectedHelperPID: pid_t? = nil) -> [String: Any] {
    let agentApp: pid_t = 4242, userApp: pid_t = 777
    let managed: Set<pid_t> = [agentApp]
    // (name, type, target, tag, HID state, posted by a computer-use helper, verdict)
    let cases: [(String, CGEventType, pid_t, Int64, Bool, Bool, GuardVerdict)] = [
        ("user key into agent app is redirected", .keyDown, agentApp, 0, true, false, .redirect),
        ("user key-up into agent app is redirected", .keyUp, agentApp, 0, true, false, .redirect),
        ("user modifier into agent app is redirected", .flagsChanged, agentApp, 0, true, false, .redirect),
        ("user click into agent app is dropped", .leftMouseDown, agentApp, 0, true, false, .drop),
        ("user scroll into agent app is dropped", .scrollWheel, agentApp, 0, true, false, .drop),
        ("untagged non-HID key into agent app is dropped", .keyDown, agentApp, 0, false, false, .drop),
        ("redirected key never re-enters an agent app", .keyDown, agentApp, InputTag.redirected, true, false, .drop),
        ("backstage key into agent app passes", .keyDown, agentApp, InputTag.agent, false, false, .pass),
        ("backstage click into agent app passes", .rightMouseDown, agentApp, InputTag.agent, false, false, .pass),
        ("user key into user app passes", .keyDown, userApp, 0, true, false, .pass),
        ("user click into user app passes", .leftMouseDown, userApp, 0, true, false, .pass),
        ("redirected key into user app passes", .keyDown, userApp, InputTag.redirected, true, false, .pass),
        ("computer-use HID key into agent app passes (not redirected)", .keyDown, agentApp, 0, true, true, .pass),
        ("computer-use click into agent app passes", .leftMouseDown, agentApp, 0, true, true, .pass),
        ("computer-use scroll into agent app passes", .scrollWheel, agentApp, 0, false, true, .pass),
        ("computer-use key into user app passes", .keyDown, userApp, 0, true, true, .pass),
        ("redirected key never re-enters an agent app, whoever posted it", .keyDown, agentApp, InputTag.redirected, true, true, .drop),
    ]
    var failures: [String] = []
    if computerUseHelpers.contains(where: { $0.requirement == nil }) { failures.append("could not compile helper signing requirements") }
    if computerUseOrigin(getpid()) != .unrelated || computerUseOrigin(0) != .unrelated {
        failures.append("backstage itself or pid 0 taken for a computer-use helper")
    }
    if let rejectedHelperPID, computerUseOrigin(rejectedHelperPID) != .rejectedHelper {
        failures.append("unsigned helper fixture was not rejected")
    }
    if classifyInput(type: .keyDown, target: agentApp, tag: 0, hidState: true, managed: managed,
                     computerUseOrigin: .rejectedHelper) != .drop {
        failures.append("rejected helper event was not dropped")
    }
    if classifyInput(type: .keyDown, target: agentApp, tag: 0, hidState: true, managed: managed, fromManagedApp: true) != .drop {
        failures.append("synthetic key from managed app could be redirected")
    }
    for (name, type, target, tag, hid, cu, want) in cases {
        // Read the fields back from a real CGEvent, as the tap does.
        let e = type == .scrollWheel ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
            : [.keyDown, .keyUp, .flagsChanged].contains(type) ? CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: type != .keyUp)
            : CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: type == .rightMouseDown ? .right : .left)
        guard let e else { failures.append("\(name): could not build event"); continue }
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        let got = classifyInput(type: type, target: target, tag: e.getIntegerValueField(.eventSourceUserData), hidState: hid, managed: managed,
                                computerUseOrigin: cu ? .verifiedHelper : .unrelated)
        if got != want { failures.append("\(name): got \(got.rawValue), want \(want.rawValue)") }
    }
    return ["ok": failures.isEmpty, "cases": cases.count + 2 + (rejectedHelperPID == nil ? 0 : 1), "failures": failures]
}
