import Foundation
import AppKit
import CoreGraphics

/// Background input: events are posted straight to the target process (CGEventPostToPid),
/// never through the HID system, so the user's cursor, keyboard focus and frontmost app
/// are untouched. Every event is tagged (`postTagged`) so the daemon's input guard
/// (InputGuard.swift) can tell it from the user's input.

private typealias SetWinLocFn = @convention(c) (CGEvent, CGPoint) -> Void
private let setWindowLocation: SetWinLocFn? = {
    guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let s = dlsym(h, "CGEventSetWindowLocation") else { return nil }
    return unsafeBitCast(s, to: SetWinLocFn.self)
}()

/// Window-number field AppKit uses to route mouse events (undocumented, field 51).
private let kWindowNumberField = CGEventField(rawValue: 51)!

struct WindowHit {
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect    // global
}

/// On-screen windows front-to-back (global coords).
func onscreenWindows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}

func cgBounds(_ w: [String: Any]) -> CGRect {
    guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r0 = CGRect(dictionaryRepresentation: b) else { return .null }
    return r0
}

/// Topmost window owned by one of `pids` containing global point `p`.
func hitTest(_ p: CGPoint, pids: Set<pid_t>) -> WindowHit? {
    for w in onscreenWindows() {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
              let layer = w[kCGWindowLayer as String] as? Int, layer < 1000,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        let b = cgBounds(w)
        if b.contains(p), let id = w[kCGWindowNumber as String] as? CGWindowID {
            return WindowHit(windowID: id, pid: pid, bounds: b)
        }
    }
    return nil
}

private func mouseEvent(_ type: CGEventType, at p: CGPoint, hit: WindowHit, button: CGMouseButton, clicks: Int) -> CGEvent {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(hit.windowID))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(hit.windowID))
    e.setIntegerValueField(kWindowNumberField, value: Int64(hit.windowID))
    setWindowLocation?(e, CGPoint(x: p.x - hit.bounds.minX, y: p.y - hit.bounds.minY))
    return e
}

/// AppKit swallows a single click on a window of an *inactive* app (it's the "activate me" click,
/// unless the view accepts first mouse). Since agent apps are never really frontmost, tell the app
/// privately that it has been activated. This only changes the app's own idea of its state: the
/// WindowServer's frontmost app, the user's menu bar and keyboard focus are untouched.
/// Only sent when the app doesn't already consider itself active (AppKit answers AXFrontmost from
/// its own state), so the app sees a single activation, like a human switching to it once.
func primeActivation(_ pid: pid_t) {
    if (axApp(pid).attr(kAXFrontmostAttribute) as? Bool) == true { return }
    guard let e = NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, subtype: NSEvent.EventSubtype.applicationActivated.rawValue, data1: 0, data2: 0),
          let cg = e.cgEvent else { return }
    cg.postTagged(to: pid)
    usleep(30_000)
}

func postClick(at p: CGPoint, hit: WindowHit, right: Bool = false, count: Int = 1) {
    let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    primeActivation(hit.pid)
    mouseEvent(.mouseMoved, at: p, hit: hit, button: btn, clicks: 0).postTagged(to: hit.pid)
    usleep(20_000)
    for c in 1...max(1, count) {
        mouseEvent(down, at: p, hit: hit, button: btn, clicks: c).postTagged(to: hit.pid)
        usleep(30_000)
        mouseEvent(up, at: p, hit: hit, button: btn, clicks: c).postTagged(to: hit.pid)
        usleep(40_000)
    }
}

func postMove(to p: CGPoint, hit: WindowHit) {
    mouseEvent(.mouseMoved, at: p, hit: hit, button: .left, clicks: 0).postTagged(to: hit.pid)
}

func postDrag(from a: CGPoint, to b: CGPoint, hit: WindowHit, steps: Int = 20) {
    primeActivation(hit.pid)
    mouseEvent(.mouseMoved, at: a, hit: hit, button: .left, clicks: 0).postTagged(to: hit.pid)
    usleep(20_000)
    mouseEvent(.leftMouseDown, at: a, hit: hit, button: .left, clicks: 1).postTagged(to: hit.pid)
    usleep(50_000)
    let segments = max(1, steps)
    for i in 1...segments {
        let t = CGFloat(i) / CGFloat(segments)
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        mouseEvent(.leftMouseDragged, at: p, hit: hit, button: .left, clicks: 1).postTagged(to: hit.pid)
        usleep(15_000)
    }
    mouseEvent(.leftMouseUp, at: b, hit: hit, button: .left, clicks: 1).postTagged(to: hit.pid)
}

func postScroll(at p: CGPoint, hit: WindowHit, dx: Int32, dy: Int32) {
    primeActivation(hit.pid)
    postMove(to: p, hit: hit)
    usleep(20_000)
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    e.location = p
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(hit.windowID))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(hit.windowID))
    e.setIntegerValueField(kWindowNumberField, value: Int64(hit.windowID))
    setWindowLocation?(e, CGPoint(x: p.x - hit.bounds.minX, y: p.y - hit.bounds.minY))
    e.postTagged(to: hit.pid)
}

// MARK: keyboard

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "keypadenter": 76,
]

/// Parse "cmd+shift+s" into keycode + flags.
func parseCombo(_ combo: String) throws -> (CGKeyCode, CGEventFlags) {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    var normalized = combo.lowercased()
    if normalized == "+" || normalized.hasSuffix("++") {
        normalized.removeLast()
        normalized += "="
        flags.insert(.maskShift)
    }
    let parts = normalized.split(separator: "+", omittingEmptySubsequences: false)
    for part in parts {
        let p = String(part)
        switch p {
        case "cmd", "command", "⌘": flags.insert(.maskCommand)
        case "shift", "⇧": flags.insert(.maskShift)
        case "alt", "opt", "option", "⌥": flags.insert(.maskAlternate)
        case "ctrl", "control", "⌃": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default:
            guard let k = keyCodes[p] else { throw CLIError("unknown key '\(p)' in '\(combo)'. Known: \(keyCodes.keys.sorted().joined(separator: " "))") }
            guard key == nil else { throw CLIError("multiple keys in combo '\(combo)'") }
            key = k
        }
    }
    guard let k = key else { throw CLIError("no key in combo '\(combo)'") }
    if [123, 124, 125, 126, 115, 119, 116, 121, 117].contains(k) { flags.insert(.maskSecondaryFn); flags.insert(.maskNumericPad) }
    return (k, flags)
}

func postKey(pid: pid_t, combo: String) throws {
    postKey(pid: pid, key: try parseCombo(combo))
}

func postKey(pid: pid_t, key: (CGKeyCode, CGEventFlags)) {
    let (k, flags) = key
    primeActivation(pid)
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down)!
        e.flags = flags
        e.postTagged(to: pid)
        usleep(15_000)
    }
}

func postText(pid: pid_t, text: String, delayMicros: UInt32 = 8_000) {
    primeActivation(pid)
    let src = CGEventSource(stateID: .privateState)
    for ch in text {
        if ch == "\n" { try? postKey(pid: pid, combo: "return"); continue }
        if ch == "\t" { try? postKey(pid: pid, combo: "tab"); continue }
        var u = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            e.postTagged(to: pid)
            usleep(delayMicros)
        }
    }
}
