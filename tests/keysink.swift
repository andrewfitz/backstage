// A windowless app that backstage doesn't manage, for tests/computer-use.sh: logs every key it
// receives ("key <chars>") to the file given. No window, no Dock tile, never activates, so it
// never shows on the user's screen; input reaches it only when something posts to its PID.
// usage: keysink <log-file>
import Cocoa

guard CommandLine.arguments.count == 2 else { print("usage: keysink <log-file>"); exit(2) }
let logPath = CommandLine.arguments[1]
FileManager.default.createFile(atPath: logPath, contents: nil)
let log = FileHandle(forWritingAtPath: logPath)!
func note(_ s: String) { log.seekToEndOfFile(); log.write((s + "\n").data(using: .utf8)!) }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
    note("key \(e.characters ?? "")")
    return e
}
DispatchQueue.main.async { note("ready \(getpid())") }
app.run()
