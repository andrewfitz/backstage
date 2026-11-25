import Foundation
import AppKit
import Carbon.HIToolbox

/// The user's settings, in BACKSTAGE_HOME/settings.json. Written by `backstage settings` and the
/// menu bar; the daemon watches the file and applies changes while it runs.
struct Settings: Codable, Equatable {
    /// Keep the status item (and the daemon) up with no apps running.
    var keepInMenuBar: Bool?
    /// The Send Front Window Backstage hotkey: a combo such as "ctrl+opt+cmd+b", or "off".
    /// nil: the default (`HotKeyCombo.defaultSpec`), except in a non-default BACKSTAGE_HOME (see
    /// `effectiveHotKey`).
    var hotkey: String?

    static var url: URL { Paths.dir.appendingPathComponent("settings.json") }

    static func load() -> Settings { readJSON(url, Settings.self) ?? Settings() }

    /// Serialize updates from the CLI and menu, preserving keys from newer versions.
    @discardableResult
    static func update(_ change: (inout Settings) -> Void) throws -> (settings: Settings, stamp: String) {
        let lock = try StateLock("settings.lock")
        defer { lock.release() }
        let destination = try configurationTarget(url)
        let data = try configurationData(destination) ?? Data("{}".utf8)
        let current = try JSONDecoder().decode(Settings.self, from: data)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("invalid settings in \(url.path)")
        }
        var updated = current
        change(&updated)
        if updated != current {
            if updated.keepInMenuBar != current.keepInMenuBar { object["keepInMenuBar"] = updated.keepInMenuBar }
            if updated.hotkey != current.hotkey { object["hotkey"] = updated.hotkey }
            let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: destination, options: .atomic)
        }
        return (updated, settingsStamp())
    }

    var keep: Bool { keepInMenuBar ?? false }

    /// The hotkey this home's daemon registers, or nil for none. A daemon in another
    /// BACKSTAGE_HOME (tests, a second login's agents) registers only a hotkey its own settings
    /// name: otherwise every such daemon would grab the default beside the user's own one, and a
    /// press could send the user's app to a display nobody looks at.
    var effectiveHotKey: String? {
        let spec = hotkey ?? (Paths.isDefaultHome ? HotKeyCombo.defaultSpec : "off")
        return spec == "off" ? nil : spec
    }

    /// For `status` and `settings`.
    func json() -> [String: Any] {
        var out: [String: Any] = ["keepInMenuBar": keep, "hotkey": effectiveHotKey ?? "off"]
        if let spec = effectiveHotKey, let combo = try? HotKeyCombo(spec) { out["hotkeySymbols"] = combo.symbols }
        if hotkey == nil, !Paths.isDefaultHome { out["hotkeyNote"] = "off by default outside ~/.backstage; set one with `backstage settings hotkey <combo>`" }
        return out
    }
}

/// A global hotkey: two or more modifiers including ⌘ or ⌃, and a letter, digit or F-key.
/// Keys are named by their position on a US keyboard (virtual key codes), as in `key`.
struct HotKeyCombo: Equatable {
    static let defaultSpec = "ctrl+opt+cmd+b"

    let key: String
    let keyCode: CGKeyCode
    let control: Bool, option: Bool, shift: Bool, command: Bool

    init(_ spec: String) throws {
        var control = false, option = false, shift = false, command = false
        var key: String?
        let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": command = true
            case "ctrl", "control", "⌃": control = true
            case "opt", "option", "alt", "⌥": option = true
            case "shift", "⇧": shift = true
            default:
                guard key == nil else { throw CLIError("more than one key in hotkey '\(spec)'") }
                key = part
            }
        }
        guard let key, !key.isEmpty else { throw CLIError("no key in hotkey '\(spec)': end it with a letter, digit or F-key, e.g. ctrl+opt+cmd+b") }
        let isFunction = key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()).map { (1...12).contains($0) } == true
        guard isFunction || (key.count == 1 && (key.first!.isLetter || key.first!.isNumber) && key.first!.isASCII),
              let code = keyCodes[key] else {
            throw CLIError("hotkey key must be a letter, a digit or F1–F12, not '\(key)'")
        }
        let modifiers = [control, option, shift, command].filter { $0 }.count
        guard modifiers >= 2, command || control else {
            throw CLIError("hotkey '\(spec)' needs at least two modifiers, one of them cmd or ctrl (e.g. ctrl+opt+cmd+b or cmd+opt+b)")
        }
        self.key = key; keyCode = code
        self.control = control; self.option = option; self.shift = shift; self.command = command
    }

    /// Canonical spelling, in the order macOS shows modifiers: "ctrl+opt+shift+cmd+b".
    var spec: String {
        ([control ? "ctrl" : nil, option ? "opt" : nil, shift ? "shift" : nil, command ? "cmd" : nil].compactMap { $0 } + [key])
            .joined(separator: "+")
    }

    /// "⌃⌥⌘B", as menus show it.
    var symbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    var carbonModifiers: UInt32 {
        UInt32((control ? controlKey : 0) | (option ? optionKey : 0) | (shift ? shiftKey : 0) | (command ? cmdKey : 0))
    }

    /// For showing the combo on a menu item.
    var keyEquivalent: String {
        if key.count > 1, let n = Int(key.dropFirst()) { return String(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!)) }
        return key
    }

    var modifierMask: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        if shift { m.insert(.shift) }
        if command { m.insert(.command) }
        return m
    }

    /// An enabled macOS keyboard shortcut (System Settings › Keyboard › Keyboard Shortcuts) with
    /// the same key and modifiers, which would take the press first.
    func systemShortcutConflict() -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return list.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return false }
            return code == Int(keyCode) && mods & relevant == carbonModifiers
        }
    }
}

/// The daemon's global hotkey (Carbon `RegisterEventHotKey`: no permission needed, works for an
/// accessory app). Events arrive through the application event target, so it needs the
/// NSApplication run loop the menu bar runs (not `BACKSTAGE_MENUBAR=off`).
final class GlobalHotKey {
    private static let signature: OSType = 0x426B_5374   // 'BkSt'
    private static var shared: GlobalHotKey?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registered: HotKeyCombo?

    init(action: @escaping () -> Void) {
        self.action = action
        GlobalHotKey.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Out of the Carbon callback before doing any work.
            DispatchQueue.main.async { GlobalHotKey.shared?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    /// Register `combo`, replacing any previous one. Returns why it couldn't, or nil.
    func register(_ combo: HotKeyCombo) -> String? {
        unregister()
        if combo.systemShortcutConflict() {
            return "\(combo.symbols) is a macOS keyboard shortcut (System Settings › Keyboard › Keyboard Shortcuts); pick another with `backstage settings hotkey <combo>`"
        }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            return status == eventHotKeyExistsErr
                ? "\(combo.symbols) is already taken by another app; pick another with `backstage settings hotkey <combo>`"
                : "\(combo.symbols) couldn't be registered (OSStatus \(status))"
        }
        ref = newRef
        registered = combo
        return nil
    }
}

/// `backstage settings` / `settings keep-in-menu-bar on|off` / `settings hotkey <combo|off>`.
func cmdSettings(_ args: Args) throws -> [String: Any] {
    let change: ((inout Settings) -> Void)?
    switch (args.pos(0), args.pos(1)) {
    case (nil, nil): change = nil
    case ("keep-in-menu-bar", let value?):
        switch value.lowercased() {
        case "on", "true", "yes", "1": change = { $0.keepInMenuBar = true }
        case "off", "false", "no", "0": change = { $0.keepInMenuBar = false }
        default: throw CLIError("usage: backstage settings keep-in-menu-bar on|off")
        }
    case ("hotkey", let value?):
        if value.lowercased() == "off" || value.lowercased() == "none" { change = { $0.hotkey = "off" } }
        else if value.lowercased() == "default" { change = { $0.hotkey = HotKeyCombo.defaultSpec } }
        else {
            let combo = try HotKeyCombo(value)
            if combo.systemShortcutConflict() {
                throw CLIError("\(combo.symbols) is a macOS keyboard shortcut (System Settings › Keyboard › Keyboard Shortcuts), which would take the press first; pick another")
            }
            change = { $0.hotkey = combo.spec }
        }
    default:
        throw CLIError("usage: backstage settings [keep-in-menu-bar on|off | hotkey <combo|off>]  (combo e.g. ctrl+opt+cmd+b)")
    }
    let update = try change.map(Settings.update)
    let settings = update?.settings ?? Settings.load()
    var out = settings.json()
    out["ok"] = true
    out["file"] = Settings.url.path
    guard let daemon = liveDaemon() else {
        out["daemon"] = "not running"
        if settings.keep { out["note"] = "run `backstage start` to bring up the menu bar icon (and the hotkey)" }
        return out
    }
    out["daemon"] = daemon.pid
    if let update {
        // The daemon picks the file up within half a second; wait for it to say what it registered.
        let want = settings.effectiveHotKey
        let published = waitFor(timeout: 3) { () -> DaemonInfo? in
            guard let d = readJSON(Paths.daemon, DaemonInfo.self),
                  d.pid == daemon.pid, d.processStart == daemon.processStart,
                  d.settingsApplied == update.stamp else { return nil }
            return d
        }
        if let d = published { out.merge(hotkeyState(d, wanted: want)) { _, new in new } }
        else if daemon.settingsApplied == nil { out["note"] = "the running daemon is from an older backstage and ignores these settings; `backstage stop --all` replaces it" }
        else { out["note"] = "the daemon hasn't applied the change yet; check `backstage status`" }
    } else {
        out.merge(hotkeyState(daemon, wanted: settings.effectiveHotKey)) { _, new in new }
    }
    return out
}

/// What the running daemon did with the hotkey, for `settings` and `status`.
func hotkeyState(_ d: DaemonInfo, wanted: String?) -> [String: Any] {
    if let error = d.hotkeyError { return ["hotkeyRegistered": false, "hotkeyError": error] }
    if let registered = d.hotkey, let wanted, let combo = try? HotKeyCombo(wanted) {
        return ["hotkeyRegistered": registered == combo.spec]
    }
    return ["hotkeyRegistered": false]
}

/// The settings file's modification stamp: the daemon publishes the one it last applied.
func settingsStamp() -> String {
    var st = stat()
    guard stat(Settings.url.path, &st) == 0 else { return "none" }
    return "\(st.st_ino)-\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)"
}
