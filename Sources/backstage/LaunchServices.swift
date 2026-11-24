import Foundation
import AppKit

/// LaunchServices' private open call and application-type accessors: what /usr/bin/open uses,
/// plus the open option that starts an app as a UIElement (no Dock tile, not in ⌘-Tab).
/// All private API, looked up at run time: when a symbol is missing, callers fall back to the
/// public behaviour (a Dock tile) instead of failing.
enum LaunchServices {
    private static let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)
    /// LaunchServices' "current session" (kLSDefaultSessionID).
    private static let session: Int32 = -2

    private typealias OpenFn = @convention(c) (CFArray, CFURL, CFDictionary, AnyObject) -> Void
    private typealias Completion = @convention(block) (CFTypeRef?, Bool, CFError?) -> Void
    private typealias ASNCreateWithPid = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetItem = @convention(c) (Int32, CFTypeRef, CFString, CFTypeRef, UnsafeMutableRawPointer?) -> OSStatus
    private typealias CopyInfo = @convention(c) (Int32, CFTypeRef?, CFArray?) -> Unmanaged<CFDictionary>?

    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }
    /// A CFString constant exported by LaunchServices (e.g. `_kLSOpenOptionHideKey`).
    static func key(_ name: String) -> String? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return p.assumingMemoryBound(to: CFString.self).pointee as String
    }

    private static let open = function("_LSOpenURLsWithCompletionHandler", OpenFn.self)
    private static let asnCreate = function("_LSASNCreateWithPid", ASNCreateWithPid.self)
    private static let copyItem = function("_LSCopyApplicationInformationItem", CopyItem.self)
    private static let setItem = function("_LSSetApplicationInformationItem", SetItem.self)
    private static let copyInfo = function("_LSCopyApplicationInformation", CopyInfo.self)
    private static let typeKey = key("_kLSApplicationTypeKey")

    /// Values of the application type.
    static let foreground = "Foreground", uiElement = "UIElement"

    struct OpenOptions {
        var hideFromDock = true
        var environment: [String: String] = [:]
        var arguments: [String] = []
        var log: URL
    }

    /// The open call and every option `launch` needs exist in this macOS.
    static var canOpen: Bool { open != nil && optionKeys != nil }
    /// The open option that starts an app as a UIElement exists.
    static var canHideFromDock: Bool { key("_kLSOpenOptionUIElementLaunchKey") != nil }

    private static let optionKeys: [String: String]? = {
        var keys: [String: String] = [:]
        for name in ["Activate", "Hide", "PreferRunningInstance", "AddToRecents", "LaunchStdOutPath",
                     "LaunchStdErrPath", "EnvironmentVariables", "Arguments"] {
            guard let k = key("_kLSOpenOption\(name)Key") else { return nil }
            keys[name] = k
        }
        return keys
    }()

    /// Launch a new, hidden, inactive instance of the app at `app` (like `open -g -j -n`, not
    /// added to recents), optionally as a UIElement. Returns the new process's PID when
    /// LaunchServices reports it (it may not, e.g. for a script executable).
    static func openApplication(_ app: URL, _ options: OpenOptions, timeout: Double = 30) throws -> pid_t? {
        guard let open, let k = optionKeys else { throw CLIError("LaunchServices open call unavailable") }
        var dict: [String: Any] = [
            k["Activate"]!: false,
            k["Hide"]!: true,
            k["PreferRunningInstance"]!: false,      // a fresh instance, never the user's copy
            k["AddToRecents"]!: false,
            // File URLs: LaunchServices ignores plain path strings here.
            k["LaunchStdOutPath"]!: options.log,
            k["LaunchStdErrPath"]!: options.log,
        ]
        if !options.environment.isEmpty { dict[k["EnvironmentVariables"]!] = options.environment }
        if !options.arguments.isEmpty { dict[k["Arguments"]!] = options.arguments }
        if options.hideFromDock, let ui = key("_kLSOpenOptionUIElementLaunchKey") { dict[ui] = true }

        final class Outcome: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var ok = false, error: String?, pid: pid_t?
        }
        let outcome = Outcome()
        let completion: Completion = { asn, ok, error in
            outcome.ok = ok
            outcome.error = error.map { String(describing: $0) }
            if let asn { outcome.pid = pid(of: asn) }
            outcome.done.signal()
        }
        // An empty (not nil) URL list: open the application itself.
        open([] as CFArray, app as CFURL, dict as CFDictionary, completion as AnyObject)
        let deadline = Date().addingTimeInterval(timeout)
        while outcome.done.wait(timeout: .now()) != .success {
            guard Date() < deadline else { throw CLIError("LaunchServices didn't answer within \(Int(timeout))s opening \(app.path)") }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard outcome.ok else { throw CLIError("LaunchServices couldn't open \(app.path): \(outcome.error ?? "unknown error")") }
        return outcome.pid
    }

    private static func pid(of asn: CFTypeRef) -> pid_t? {
        guard let copyInfo, let info = copyInfo(session, asn, nil)?.takeRetainedValue() as? [String: Any],
              let pid = (info["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    private static func asn(_ pid: pid_t) -> CFTypeRef? { asnCreate?(nil, pid)?.takeRetainedValue() }

    private static func item(_ pid: pid_t, _ key: String) -> CFTypeRef? {
        guard let copyItem, let asn = asn(pid) else { return nil }
        return copyItem(session, asn, key as CFString)?.takeRetainedValue()
    }

    /// "Foreground" (Dock tile, ⌘-Tab), "UIElement", "BackgroundOnly", or nil if unknown.
    static func applicationType(_ pid: pid_t) -> String? {
        typeKey.flatMap { item(pid, $0) as? String }
    }

    /// The type LaunchServices would restore the app to: "Foreground" for an app launched as a
    /// UIElement by the open option, nil for one whose own Info.plist makes it a UIElement.
    static func typeToRestore(_ pid: pid_t) -> String? {
        item(pid, "LSApplicationTypeToRestore") as? String
    }

    /// Set the app's type, then read it back: a refused set also returns noErr.
    static func setApplicationType(_ pid: pid_t, _ type: String) -> Bool {
        guard let setItem, let typeKey, let asn = asn(pid) else { return false }
        _ = setItem(session, asn, typeKey as CFString, type as CFString, nil)
        return applicationType(pid) == type
    }
}

/// Whether a launched app is in the Dock, for `launch`'s `dock` field. Waits until `deadline`
/// (system uptime) for an app that promotes itself to a regular app shortly after launch.
func dockState(_ pid: pid_t, requested: Bool, hidden: Bool, until deadline: TimeInterval) -> String {
    guard hidden else { return requested ? "visible (this macOS lacks the LaunchServices option that hides it)" : "visible (--dock)" }
    var type = LaunchServices.applicationType(pid)
    while type != LaunchServices.foreground && ProcessInfo.processInfo.systemUptime < deadline {
        pump(0.05)
        type = LaunchServices.applicationType(pid)
    }
    switch type {
    case LaunchServices.foreground?: return "visible (app made itself a regular app)"
    case nil: return "unknown"
    default: return "hidden"
    }
}

/// Before `show` hands an app over: give an app `launch` hid from the Dock its Dock tile and
/// ⌘-Tab entry back. Returns "restored", "visible" (it already had one) or why not.
func restoreDock(_ pid: pid_t) -> String {
    guard let type = LaunchServices.applicationType(pid) else { return "unknown (LaunchServices has no record of the app)" }
    if type == LaunchServices.foreground { return "visible" }
    guard type == LaunchServices.uiElement else { return "not restored: the app is a background-only app" }
    guard LaunchServices.typeToRestore(pid) == LaunchServices.foreground else {
        return "not restored: the app is a menu bar or agent app (its Info.plist sets LSUIElement), so it never has a Dock tile"
    }
    // A brief retry: the set can race the app's own launch-time check-in.
    for attempt in 0..<3 {
        if LaunchServices.setApplicationType(pid, LaunchServices.foreground) { return "restored" }
        if attempt < 2 { pump(0.1) }
    }
    return "not restored: LaunchServices refused to make the app a regular app"
}
