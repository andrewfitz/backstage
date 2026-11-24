// Input from "someone else" for tests/focus.sh: posts one character as a key down/up pair straight
// to one process (CGEventPostToPid, never the HID system, so it can't reach any other app) without
// backstage's tag. The daemon's input guard must drop it before it reaches a managed app.
// tests/computer-use.sh also runs copies at computer-use helpers' paths, whose keys must pass.
// usage: untagged <pid> <character>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]), let ch = CommandLine.arguments[2].first else {
    print("usage: untagged <pid> <character>"); exit(2)
}
let source = CGEventSource(stateID: .privateState)
var utf16 = Array(String(ch).utf16)
for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { exit(1) }
    e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    e.postToPid(pid)
    usleep(15_000)
}
// Stay alive until the events are delivered: the guard looks up the posting process's path then
// (computer-use helpers are long-lived processes).
usleep(300_000)
