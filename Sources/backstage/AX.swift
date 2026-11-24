import Foundation
import AppKit
import ApplicationServices

extension AXUIElement {
    func attr(_ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, a as CFString, &v) == .success ? v : nil
    }
    func str(_ a: String) -> String? {
        guard let v = attr(a) else { return nil }
        return Self.stringValue(v)
    }
    fileprivate static func stringValue(_ v: CFTypeRef) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }
    var role: String { str(kAXRoleAttribute) ?? "?" }
    var children: [AXUIElement] { (attr(kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    var windows: [AXUIElement] { (attr(kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    func readElements(_ attribute: String) throws -> [AXUIElement] {
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(self, attribute as CFString, &result)
        // Children an element can't list (unsupported, or a failure some SwiftUI and AppKit
        // elements report instead of an empty list) are treated as none.
        if status == .noValue || (attribute == kAXChildrenAttribute && (status == .attributeUnsupported || status == .failure)) { return [] }
        guard status == .success, let elements = result as? [AXUIElement] else {
            throw CLIError("cannot read \(attribute) (AXError \(status.rawValue))")
        }
        return elements
    }
    var actions: [String] {
        var a: CFArray?
        guard AXUIElementCopyActionNames(self, &a) == .success, let arr = a as? [String] else { return [] }
        return arr
    }
    var position: CGPoint? {
        guard let v = attr(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    var size: CGSize? {
        guard let v = attr(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero; return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }
    @discardableResult func setPosition(_ p: CGPoint) -> AXError {
        var pt = p
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pt)!)
    }
    @discardableResult func setSize(_ s: CGSize) -> AXError {
        var sz = s
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sz)!)
    }
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success ? id : nil
    }
    var pid: pid_t { var p: pid_t = 0; AXUIElementGetPid(self, &p); return p }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func axApp(_ pid: pid_t) -> AXUIElement {
    let a = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(a, 3)
    return a
}

/// Element references look like "w8432.3.1": window ID, then child indices. Window IDs don't change
/// when windows reorder; child indices are stable as long as that part of the UI doesn't change.
/// A bare leading integer ("0.3.1") is accepted as a window *index* (front-to-back).
func resolveWindow(_ pid: pid_t, _ spec: String) throws -> AXUIElement {
    let wins = try axApp(pid).readElements(kAXWindowsAttribute)
    if spec.hasPrefix("w"), let id = CGWindowID(spec.dropFirst()) {
        guard let w = wins.first(where: { $0.windowID == id }) else {
            throw CLIError("window \(spec) not found (closed?). Windows: \(wins.compactMap { $0.windowID }.map { "w\($0)" }.joined(separator: " "))")
        }
        return w
    }
    guard let i = Int(spec), i >= 0, i < wins.count else { throw CLIError("bad window '\(spec)' (\(wins.count) windows)") }
    return wins[i]
}

func windowRef(_ w: AXUIElement, index: Int) -> String { w.windowID.map { "w\($0)" } ?? "\(index)" }

func resolveRef(_ pid: pid_t, _ ref: String) throws -> AXUIElement {
    let parts = ref.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard let first = parts.first else { throw CLIError("empty element ref") }
    var e = try resolveWindow(pid, first)
    for p in parts.dropFirst() {
        guard let i = Int(p), i >= 0 else { throw CLIError("bad element ref '\(ref)' (expected like w1234.3.1)") }
        let c = try e.readElements(kAXChildrenAttribute)
        guard i < c.count else { throw CLIError("element ref '\(ref)' no longer valid (UI changed?) — re-run tree/find") }
        e = c[i]
    }
    return e
}

struct ElementInfo {
    let ref: String
    let depth: Int
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let desc: String?
    let identifier: String?
    let frame: CGRect?
    let element: AXUIElement
    let enabled: Bool?
    let focused: Bool?

    var label: String {
        [title, desc, value, identifier].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func json(origin: CGPoint) -> [String: Any] {
        var d: [String: Any] = ["ref": ref, "role": role]
        if let subrole { d["subrole"] = subrole }
        if let title, !title.isEmpty { d["title"] = title }
        if let value, !value.isEmpty { d["value"] = value }
        if let desc, !desc.isEmpty { d["description"] = desc }
        if let identifier, !identifier.isEmpty { d["identifier"] = identifier }
        if let f = frame { d["frame"] = rectDict(f.offsetBy(dx: -origin.x, dy: -origin.y)) }
        let actions = element.actions
        if !actions.isEmpty { d["actions"] = actions }
        if enabled == false { d["enabled"] = false }
        if focused == true { d["focused"] = true }
        return d
    }

    func line(origin: CGPoint) -> String {
        var s = String(repeating: "  ", count: depth) + "[\(ref)] \(role.replacingOccurrences(of: "AX", with: ""))"
        if let subrole, subrole != "AXUnknown" { s += "(\(subrole.replacingOccurrences(of: "AX", with: "")))" }
        func q(_ t: String) -> String { let t1 = t.replacingOccurrences(of: "\n", with: "⏎"); return t1.count > 80 ? String(t1.prefix(80)) + "…" : t1 }
        if let title, !title.isEmpty { s += " \"\(q(title))\"" }
        if let value, !value.isEmpty { s += " value=\"\(q(value))\"" }
        if let desc, !desc.isEmpty, desc != title { s += " desc=\"\(q(desc))\"" }
        if let identifier, !identifier.isEmpty { s += " id=\(identifier)" }
        if let f = frame { let o = f.offsetBy(dx: -origin.x, dy: -origin.y); s += " @\(r(o.minX)),\(r(o.minY)) \(r(o.width))x\(r(o.height))" }
        let acts = element.actions.filter { !["AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI"].contains($0) }
            .map { $0.replacingOccurrences(of: "AX", with: "").lowercased() }
        if !acts.isEmpty { s += " {\(acts.joined(separator: ","))}" }
        if enabled == false { s += " (disabled)" }
        if focused == true { s += " (focused)" }
        return s
    }
}

private enum InfoAttribute: Int, CaseIterable {
    case role, subrole, title, value, description, help, identifier, position, size, enabled, focused

    var name: String {
        switch self {
        case .role: return kAXRoleAttribute
        case .subrole: return kAXSubroleAttribute
        case .title: return kAXTitleAttribute
        case .value: return kAXValueAttribute
        case .description: return kAXDescriptionAttribute
        case .help: return kAXHelpAttribute
        case .identifier: return kAXIdentifierAttribute
        case .position: return kAXPositionAttribute
        case .size: return kAXSizeAttribute
        case .enabled: return kAXEnabledAttribute
        case .focused: return kAXFocusedAttribute
        }
    }
}

private let infoAttributes = InfoAttribute.allCases.map(\.name) as CFArray

func info(_ e: AXUIElement, ref: String, depth: Int) throws -> ElementInfo {
    var result: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(e, infoAttributes, [], &result)
    guard status == .success, let values = result as? [AnyObject], values.count == InfoAttribute.allCases.count else {
        throw CLIError("cannot inspect element '\(ref)' (AXError \(status.rawValue))")
    }
    for value in values where CFGetTypeID(value) == AXValueGetTypeID() {
        var error = AXError.success
        // A failure for one attribute is a missing value: SwiftUI and AppKit elements report it
        // for attributes they don't have (Calculator's toolbar buttons' subrole, an open panel's
        // sidebar value). Errors about the element itself (gone, app not responding) still fail.
        if AXValueGetValue(value as! AXValue, .axError, &error),
           error != .noValue, error != .attributeUnsupported, error != .notImplemented, error != .failure {
            throw CLIError("cannot read attributes of '\(ref)' (AXError \(error.rawValue))")
        }
    }
    func value(_ attribute: InfoAttribute) -> CFTypeRef? {
        values[attribute.rawValue]
    }
    func string(_ attribute: InfoAttribute) -> String? { value(attribute).flatMap(AXUIElement.stringValue) }
    var frame: CGRect?
    var position = CGPoint.zero
    var size = CGSize.zero
    if let p = value(.position), let s = value(.size),
       CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
       AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size) {
        frame = CGRect(origin: position, size: size)
    }
    return ElementInfo(ref: ref, depth: depth, role: string(.role) ?? "?", subrole: string(.subrole),
                       title: string(.title), value: string(.value), desc: string(.description) ?? string(.help),
                       identifier: string(.identifier), frame: frame, element: e,
                       enabled: value(.enabled) as? Bool, focused: value(.focused) as? Bool)
}

/// Depth-first walk of one window (or all windows) yielding ElementInfo.
func walkTree(pid: pid_t, window: String?, maxDepth: Int, maxNodes: Int = 4000, _ visit: (ElementInfo, AXUIElement) -> Bool) throws {
    let windows: [AXUIElement]
    if let window { windows = [try resolveWindow(pid, window)] }
    else { windows = try axApp(pid).readElements(kAXWindowsAttribute) }
    var stack = windows.enumerated().reversed().map { index, element in
        (element, element.windowID.map { "w\($0)" } ?? window ?? "\(index)", 0)
    }
    var count = 0
    while let (element, ref, depth) = stack.popLast() {
        guard count < maxNodes else { throw CLIError("tree exceeds \(maxNodes) elements; narrow the window or depth") }
        count += 1
        let shouldContinue = try autoreleasepool { visit(try info(element, ref: ref, depth: depth), element) }
        if !shouldContinue { return }
        if depth >= maxDepth { continue }
        let children = try element.readElements(kAXChildrenAttribute)
        for (index, child) in children.enumerated().reversed() {
            stack.append((child, "\(ref).\(index)", depth + 1))
        }
    }
}

func axWindowsSummary(_ pid: pid_t, origin: CGPoint) -> [[String: Any]] {
    axApp(pid).windows.enumerated().map { (i, w) in
        var d: [String: Any] = ["ref": windowRef(w, index: i), "index": i, "title": w.str(kAXTitleAttribute) ?? "", "role": w.str(kAXSubroleAttribute) ?? w.role]
        if let f = w.frame { d["frame"] = rectDict(f.offsetBy(dx: -origin.x, dy: -origin.y)) }
        if let id = w.windowID { d["windowID"] = id }
        if (w.attr(kAXMinimizedAttribute) as? Bool) == true { d["minimized"] = true }
        return d
    }
}

/// Press a menu item by path, e.g. "File > Save As…". Matching is case-insensitive and prefix-tolerant.
func pressMenu(pid: pid_t, path: String) throws {
    let parts = path.split(separator: ">", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard parts.allSatisfy({ !$0.isEmpty }) else { throw CLIError("empty item in menu path") }
    guard let bar = axApp(pid).attr(kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw CLIError("app has no menu bar") }
    var current = bar as! AXUIElement
    for (i, want) in parts.enumerated() {
        var items = current.children
        // Menu bar items and menu items both hold their items under an AXMenu child.
        if current.role == "AXMenuBarItem" || current.role == "AXMenuItem" { items = current.children.first?.children ?? [] }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces) }
        let w = norm(want)
        guard let hit = items.first(where: { norm($0.str(kAXTitleAttribute) ?? "") == w })
                ?? items.first(where: { norm($0.str(kAXTitleAttribute) ?? "").hasPrefix(w) }) else {
            let avail = items.compactMap { $0.str(kAXTitleAttribute) }.filter { !$0.isEmpty }
            throw CLIError("menu item '\(want)' not found; available: \(avail.joined(separator: " | "))")
        }
        if i == parts.count - 1 {
            let rc = AXUIElementPerformAction(hit, kAXPressAction as CFString)
            guard rc == .success else { throw CLIError("menu press failed (AXError \(rc.rawValue))") }
        }
        current = hit
    }
}
