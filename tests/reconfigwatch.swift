// Counts display reconfigurations (what a monitor can blank for) until a stop file appears.
// usage: reconfigwatch --stop FILE [--max SECONDS]  |  reconfigwatch --online DISPLAY_ID
// Prints "watching" once registered, then on exit one line per event and "events=N".
import AppKit
import CoreGraphics
import Foundation

// reconfigwatch --online ID: prints yes or no.
let argv = CommandLine.arguments
if argv.count == 3, argv[1] == "--online", let id = UInt32(argv[2]) {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var n: UInt32 = 0
    _ = CGGetOnlineDisplayList(32, &ids, &n)
    print(ids.prefix(Int(n)).contains(id) ? "yes" : "no")
    exit(0)
}
var stopFile = "", maxSeconds = 120.0
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--stop": stopFile = argv[i + 1]; i += 2
    case "--max": maxSeconds = Double(argv[i + 1]) ?? 120; i += 2
    default: FileHandle.standardError.write(Data("unknown argument \(argv[i])\n".utf8)); exit(2)
    }
}
guard !stopFile.isEmpty else { FileHandle.standardError.write(Data("--stop FILE is required\n".utf8)); exit(2) }

final class Log { var lines: [String] = []; var count = 0 }
let log = Log()
let start = Date()
let callback: CGDisplayReconfigurationCallBack = { display, flags, user in
    // Every change is announced twice: once with only the begin flag, once with what changed.
    guard !flags.contains(.beginConfigurationFlag), let user else { return }
    let log = Unmanaged<Log>.fromOpaque(user).takeUnretainedValue()
    log.count += 1
    var what: [String] = []
    if flags.contains(.addFlag) { what.append("add") }
    if flags.contains(.removeFlag) { what.append("remove") }
    if flags.contains(.movedFlag) { what.append("moved") }
    if flags.contains(.setModeFlag) { what.append("mode") }
    if flags.contains(.setMainFlag) { what.append("main") }
    if flags.contains(.enabledFlag) { what.append("enabled") }
    if flags.contains(.disabledFlag) { what.append("disabled") }
    if flags.contains(.desktopShapeChangedFlag) { what.append("shape") }
    log.lines.append(String(format: "event %.2fs display %u %@", Date().timeIntervalSince(start), display, what.joined(separator: ",")))
}
// Reconfiguration callbacks need this process connected to the window server, as an app is.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
_ = CGMainDisplayID()
CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(log).toOpaque())
// A second, independent signal: AppKit's screen-change notification.
var screenChanges = 0
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { _ in
    screenChanges += 1
}
print("watching")
fflush(stdout)
while !FileManager.default.fileExists(atPath: stopFile) && Date().timeIntervalSince(start) < maxSeconds {
    if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}
for line in log.lines { print(line) }
print("screenChanges=\(screenChanges)")
print("events=\(log.count)")
