// Measurement helper for tests/load.sh. Never creates windows or takes focus.
//   probe displays                               -> JSON: every active display (user + agent)
//   probe shareable <interval-ms> <stop-file> [lock-file]
//                                                -> one JSON line per SCShareableContent call
//                                                   until stop-file exists
// `shareable` times the same call backstage makes before every app screenshot
// (SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)), from outside
// backstage, so it can be measured on its own while the load runs. It refuses to run without
// Screen Recording permission instead of risking a permission prompt on the user's screen.
// Simultaneous ScreenCaptureKit calls from two processes can hang on macOS 27.0.1, so with a
// lock file (backstage's BACKSTAGE_HOME/capture.lock) each call holds that flock, as backstage's
// own captures do, and the wait is reported separately. A call still unanswered after 20 s
// prints a "hung" line and exits, which releases the lock.
import Cocoa
import ScreenCaptureKit

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "displays":
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 64)
    CGGetActiveDisplayList(64, &ids, &count)
    let displays: [[String: Any]] = ids[0..<Int(count)].map { id in
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        return [
            "id": id,
            "agentDisplay": CGDisplayVendorNumber(id) == 0xB57A,
            "main": CGDisplayIsMain(id) != 0,
            "points": ["x": bounds.minX, "y": bounds.minY, "w": bounds.width, "h": bounds.height],
            "pixels": ["w": mode?.pixelWidth ?? 0, "h": mode?.pixelHeight ?? 0],
            "refreshHz": mode?.refreshRate ?? 0,
        ]
    }
    emit(["displays": displays])
case "shareable":
    guard args.count == 4 || args.count == 5, let interval = Double(args[2]) else {
        FileHandle.standardError.write(Data("usage: probe shareable <interval-ms> <stop-file> [lock-file]\n".utf8))
        exit(2)
    }
    guard CGPreflightScreenCaptureAccess() else {
        emit(["error": "no Screen Recording permission; SCShareableContent not probed"])
        exit(3)
    }
    let stopFile = args[3]
    let lockFD: Int32 = args.count == 5 ? open(args[4], O_CREAT | O_RDWR | O_CLOEXEC, 0o600) : -1
    let inFlight = NSLock()
    var callStarted: Date? = nil
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            let since = inFlight.withLock { callStarted }
            if let since, Date().timeIntervalSince(since) > 20 {
                emit(["t": since.timeIntervalSince1970, "ok": false, "hung": true, "error": "no reply in 20 s"])
                exit(4)
            }
        }
    }
    while !FileManager.default.fileExists(atPath: stopFile) {
        let started = Date()
        if lockFD >= 0 { while flock(lockFD, LOCK_EX) != 0 && errno == EINTR {} }
        let locked = Date()
        inFlight.withLock { callStarted = locked }
        var line: [String: Any] = ["t": started.timeIntervalSince1970, "lockMs": locked.timeIntervalSince(started) * 1000]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            line["windows"] = content.windows.count
            line["ok"] = true
        } catch {
            line["ok"] = false
            line["error"] = "\(error)"
        }
        line["ms"] = Date().timeIntervalSince(locked) * 1000
        inFlight.withLock { callStarted = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN) }
        emit(line)
        let left = interval / 1000 - Date().timeIntervalSince(started)
        if left > 0 { try await Task.sleep(nanoseconds: UInt64(left * 1e9)) }
    }
default:
    FileHandle.standardError.write(Data("usage: probe displays | probe shareable <interval-ms> <stop-file> [lock-file]\n".utf8))
    exit(2)
}
