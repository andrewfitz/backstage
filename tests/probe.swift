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
// lock file (backstage's BACKSTAGE_HOME/capture.lock) each call takes it first, then takes
// the per-user capture lock, matching backstage's order. The per-user lock also serializes
// standalone probes with other homes. A call still unanswered after 20 s prints a "hung"
// line and exits, which releases the locks.
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
    guard CGGetActiveDisplayList(64, &ids, &count) == .success else {
        emit(["error": "could not enumerate active displays"])
        exit(1)
    }
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
    guard args.count == 4 || args.count == 5, let interval = Double(args[2]), interval.isFinite, interval > 0 else {
        FileHandle.standardError.write(Data("usage: probe shareable <interval-ms> <stop-file> [lock-file]\n".utf8))
        exit(2)
    }
    guard CGPreflightScreenCaptureAccess() else {
        emit(["error": "no Screen Recording permission; SCShareableContent not probed"])
        exit(3)
    }
    let stopFile = args[3]
    let userLockPath = "/tmp/backstage-\(getuid())-capture.lock"
    let lockPaths = args.count == 5 ? [args[4], userLockPath] : [userLockPath]
    let captureLocks = lockPaths.map { path in
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            emit(["error": "could not open capture lock \(path): \(String(cString: strerror(errno)))"])
            exit(5)
        }
        return (path: path, fd: fd)
    }
    let inFlight = NSLock()
    var callStarted: (wall: Date, tick: TimeInterval)? = nil
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            inFlight.withLock {
                if let since = callStarted, ProcessInfo.processInfo.systemUptime - since.tick > 20 {
                    emit(["t": since.wall.timeIntervalSince1970, "ok": false, "hung": true, "error": "no reply in 20 s"])
                    exit(4)
                }
            }
        }
    }
    while !FileManager.default.fileExists(atPath: stopFile) {
        let started = ProcessInfo.processInfo.systemUptime
        for lock in captureLocks {
            while flock(lock.fd, LOCK_EX) != 0 {
                if errno == EINTR { continue }
                emit(["error": "could not acquire capture lock \(lock.path): \(String(cString: strerror(errno)))"])
                exit(5)
            }
        }
        if FileManager.default.fileExists(atPath: stopFile) { break }
        let locked = (wall: Date(), tick: ProcessInfo.processInfo.systemUptime)
        inFlight.withLock { callStarted = locked }
        var line: [String: Any] = ["t": locked.wall.timeIntervalSince1970, "lockMs": (locked.tick - started) * 1000]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            line["windows"] = content.windows.count
            line["ok"] = true
        } catch {
            line["ok"] = false
            line["error"] = "\(error)"
        }
        line["ms"] = (ProcessInfo.processInfo.systemUptime - locked.tick) * 1000
        inFlight.withLock { callStarted = nil }
        for lock in captureLocks.reversed() { flock(lock.fd, LOCK_UN) }
        emit(line)
        while !FileManager.default.fileExists(atPath: stopFile) {
            let left = interval / 1000 - (ProcessInfo.processInfo.systemUptime - started)
            if left <= 0 { break }
            try await Task.sleep(for: .seconds(min(left, 0.1)))
        }
    }
default:
    FileHandle.standardError.write(Data("usage: probe displays | probe shareable <interval-ms> <stop-file> [lock-file]\n".utf8))
    exit(2)
}
