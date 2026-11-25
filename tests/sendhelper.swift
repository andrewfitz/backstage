// Helpers for tests/send.sh. Nothing here takes focus, presses anything or shows a window.
//   sendhelper items <pid>                     the status items of <pid>'s menu bar extras, read
//                                              through accessibility (never pressed): JSON
//   sendhelper hold <keycode> <carbon-mods> <stop-file>
//                                              register a global hotkey (as another app would),
//                                              print "held" or "failed <status>", keep it until
//                                              the stop file exists
//   sendhelper launch <App.app> [KEY=VALUE…]   open a new instance hidden and in the background
//                                              (LaunchServices' launch-and-hide, as `open -g -j -n`),
//                                              print its pid
//   sendhelper terminate <pid> <App.app>       terminate only the named fixture instance
import AppKit
import Carbon.HIToolbox

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }

switch args.count > 1 ? args[1] : "" {
case "items":
    guard args.count == 3, let pid = pid_t(args[2]) else { fail("usage: sendhelper items <pid>") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
    var bar: CFTypeRef?
    var items: [[String: Any]] = []
    if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar {
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
           let list = children as? [AXUIElement] {
            for child in list {
                var entry: [String: Any] = [:]
                for (key, attribute) in [("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute), ("help", kAXHelpAttribute)] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, attribute as CFString, &value) == .success, let s = value as? String { entry[key] = s }
                }
                items.append(entry)
            }
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: ["items": items], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "hold":
    guard args.count == 5, let code = UInt32(args[2]), let mods = UInt32(args[3]) else { fail("usage: sendhelper hold <keycode> <mods> <stop-file>") }
    _ = NSApplication.shared
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x54657374, id: 7), GetApplicationEventTarget(), 0, &ref)
    print(status == noErr ? "held" : "failed \(status)")
    fflush(stdout)
    let stop = args[4]
    let deadline = Date().addingTimeInterval(120)
    while !FileManager.default.fileExists(atPath: stop) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if let ref { UnregisterEventHotKey(ref) }
case "launch":
    guard args.count >= 3 else { fail("usage: sendhelper launch <App.app> [KEY=VALUE…]") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.hides = true
    config.createsNewApplicationInstance = true
    config.addsToRecentItems = false
    var env: [String: String] = [:]
    for pair in args.dropFirst(3) {
        guard let eq = pair.firstIndex(of: "=") else { fail("bad KEY=VALUE: \(pair)") }
        env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
    }
    config.environment = env
    var result: (NSRunningApplication?, Error?)?
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args[2]), configuration: config) { app, error in result = (app, error) }
    let deadline = Date().addingTimeInterval(30)
    while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard let (app, error) = result, let app else { fail("launch failed: \(String(describing: result?.1))") }
    _ = error
    print(app.processIdentifier)
case "terminate":
    guard args.count == 4, let pid = pid_t(args[2]), pid > 0 else { fail("usage: sendhelper terminate <pid> <App.app>") }
    let expected = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
    guard let app = NSRunningApplication(processIdentifier: pid),
          app.bundleURL?.resolvingSymlinksInPath() == expected else { break }
    if !app.forceTerminate() && !app.isTerminated { fail("could not terminate fixture at \(expected.path)") }
default:
    fail("usage: sendhelper items|hold|launch|terminate …")
}
