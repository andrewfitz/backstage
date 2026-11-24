import Foundation
import AppKit

/// Shared state between the CLI and the daemon lives in ~/.backstage as small JSON files.
enum Paths {
    static let dir: URL = {
        if let o = ProcessInfo.processInfo.environment["BACKSTAGE_HOME"] { return URL(fileURLWithPath: o) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".backstage")
    }()
    static var daemon: URL { dir.appendingPathComponent("daemon.json") }
    static var apps: URL { dir.appendingPathComponent("apps.json") }
    static var log: URL { dir.appendingPathComponent("daemon.log") }
    static var shots: URL { dir.appendingPathComponent("shots") }
    static var wrappers: URL { dir.appendingPathComponent("wrappers") }
    static var appLogs: URL { dir.appendingPathComponent("logs") }
    static func ensureDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var result = mkdir(path, 0o700)
        if result != 0 && errno == ENOENT {
            let parent = url.standardizedFileURL.deletingLastPathComponent()
            guard parent.path != path else { throw CLIError("missing state directory parent") }
            try ensureDirectory(parent)
            result = mkdir(path, 0o700)
        }
        if result == 0 { return }
        if errno == EEXIST {
            var metadata = stat()
            if stat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR { return }
        }
        throw CLIError("cannot create state directory at " + path)
    }

    static func ensure() throws {
        for d in [dir, shots, wrappers, appLogs] { try ensureDirectory(d) }
    }
}

struct DaemonInfo: Codable {
    var pid: Int32
    var displayID: UInt32
    var x: Double, y: Double, width: Double, height: Double
    var startedAt: Double
    var processStart: UInt64? = nil
    /// The CLI/daemon protocol, bumped when they stop understanding each other's locks or
    /// records. Absent before sessions existed (protocol 1).
    var `protocol`: Int? = nil
    /// The daemon has been asked to shut down (SIGTERM, display lost) and is waiting to quit
    /// its apps. Launches wait for it to exit and start a fresh daemon instead of using it.
    var stopping: Bool? = nil
    /// Where the display's size came from: "main display" or "env" (BACKSTAGE_WIDTH/HEIGHT).
    var sizeSource: String? = nil
    /// The daemon's input guard (InputGuard.swift) is running. Input commands refuse without it.
    var inputGuard: Bool? = nil
    /// The daemon's audio tap manager passed its mute self-test (AudioTaps.swift). `launch`
    /// refuses without it; absent in daemons from before audio.
    var audio: Bool? = nil
    var audioReason: String? = nil
    /// The tap manager measures only apps launched with --audio (AudioMode). Absent in daemons
    /// that measure every app.
    var audioModes: Bool? = nil
    /// The daemon can register a launch that appears after its CLI stopped waiting.
    var delayedLaunchHandoff: Bool? = nil

    static let currentProtocol = 2
    var protocolMismatch: Bool { (self.protocol ?? 1) != DaemonInfo.currentProtocol }
    var matchesProcess: Bool {
        guard let start = processBirth(pid) else { return false }
        if let processStart { return start == processStart }
        return Double(start) / 1e6 <= startedAt && isDaemonCommand(pid)
    }
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct ManagedApp: Codable, Equatable {
    var pid: Int32
    var name: String
    var bundleID: String?
    var path: String
    var launchedAt: Double
    var stdout: String?
    var processStart: UInt64? = nil
    /// The agent process (e.g. claude, codex, grok) that ran `launch`, for the menu bar stats.
    var agent: String? = nil
    var agentPID: Int32? = nil
    /// The session that launched the app (see Session). nil for records from before sessions.
    var session: String? = nil
    /// How launch handled its sound: "inaudible", "muted" or "metered" (AudioMode). nil for
    /// records from before modes, which were metered.
    var audio: String? = nil

    var owner: String { session ?? Session.legacy }
    var audioMode: AudioMode { AudioMode(audio) }

    /// LaunchServices may have no application object for a wrapped executable.
    func requestTermination(force: Bool) throws {
        guard matchesProcess else { return }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.processIdentifier == pid, !app.isTerminated {
            let accepted = force ? app.forceTerminate() : app.terminate()
            if accepted || !force { return }
        }
        guard matchesProcess else { return }
        if kill(pid, force ? SIGKILL : SIGTERM) != 0, errno != ESRCH {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    var matchesProcess: Bool {
        guard let start = processBirth(pid) else { return false }
        if let processStart { return start == processStart }
        guard Double(start) / 1e6 <= launchedAt,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleURL?.resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}

func processBirth(_ pid: pid_t) -> UInt64? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_status != SZOMB else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

// Old installations wrote no process birth time. Validate their actual command before signaling.
private func isDaemonCommand(_ pid: pid_t) -> Bool {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return false }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0,
          bytes.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) == 2 else { return false }
    let args = bytes[4..<size].split(separator: 0, maxSplits: 3)
    return args.count >= 3 && args[2].elementsEqual("__daemon".utf8)
        && URL(fileURLWithPath: String(decoding: args[0], as: UTF8.self)).lastPathComponent == "backstage"
}

/// An flock in BACKSTAGE_HOME, held until `release()` or deinit. See `Locks` for the order.
final class StateLock {
    private(set) var fd: Int32

    init(_ name: String, nonblocking: Bool = false, shared: Bool = false) throws {
        let url = Paths.dir.appendingPathComponent(name)
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let path = url.path
        while true {
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CLIError("cannot open lock at " + path) }
            while flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | (nonblocking ? LOCK_NB : 0)) != 0 {
                if errno == EINTR { continue }
                let error = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            // Lock files of dead apps and old sessions are pruned (unlinked under the lock). If
            // that happened while this waited, the lock is on an orphaned file: start over.
            var held = stat(), current = stat()
            guard fstat(descriptor, &held) == 0 else {
                let error = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            if stat(path, &current) == 0 {
                if held.st_dev != current.st_dev || held.st_ino != current.st_ino {
                    close(descriptor)
                    continue
                }
                fd = descriptor
                return
            }
            let error = errno
            close(descriptor)
            guard error == ENOENT || error == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
    }

    /// True if the error is a non-blocking lock attempt finding the lock held.
    static func isBusy(_ error: Error) -> Bool {
        (error as? POSIXError).map { $0.code.rawValue == EWOULDBLOCK } ?? false
    }

    func release() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// A session's last `stop` timestamp, read and written under the lock.
    func readStamp() throws -> Double? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var count: Int
        repeat { count = pread(fd, &buffer, buffer.count, 0) } while count < 0 && errno == EINTR
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if count == 0 { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard count < buffer.count, let stamp = Double(text), stamp.isFinite else {
            throw CLIError("invalid session stop timestamp")
        }
        return stamp
    }

    func writeStamp(_ value: Double) throws {
        let text = Array(String(value).utf8)
        try text.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pwrite(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(count == 0 ? .EIO : POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        while ftruncate(fd, off_t(text.count)) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    deinit { release() }
}

func readJSON<T: Decodable>(_ url: URL, _ type: T.Type) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func writeJSON<T: Encodable>(_ url: URL, _ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(value).write(to: url, options: .atomic)
}

func processAlive(_ pid: Int32) -> Bool { processBirth(pid) != nil }

enum AppStore {
    private static func readRecords(allowMissing: Bool) throws -> [ManagedApp]? {
        do {
            return try JSONDecoder().decode([ManagedApp].self, from: Data(contentsOf: Paths.apps))
        } catch CocoaError.fileReadNoSuchFile where allowMissing { return nil }
    }

    static func read(allowMissing: Bool = true, matching: (ManagedApp) -> Bool = { _ in true }) throws -> [ManagedApp] {
        try readRecords(allowMissing: allowMissing)?.filter { matching($0) && $0.matchesProcess } ?? []
    }

    static func load() -> [ManagedApp] { (try? read()) ?? [] }

    static func add(_ a: ManagedApp) throws {
        var app = a
        guard let birth = processBirth(a.pid), a.processStart.map({ $0 == birth }) ?? true,
              Double(birth) / 1e6 <= a.launchedAt else {
            throw CLIError("managed process exited during launch")
        }
        app.processStart = birth
        try update { $0.removeAll { $0.pid == a.pid }; $0.append(app) }
    }

    static func remove(_ pid: Int32) throws {
        try update { $0.removeAll { $0.pid == pid } }
    }

    static func update(_ change: (inout [ManagedApp]) throws -> Void) throws {
        let lock = try StateLock("lock")
        try withExtendedLifetime(lock) {
            let records = try readRecords(allowMissing: true)
            var apps = records?.filter { $0.matchesProcess } ?? []
            try change(&apps)
            let unchanged = records?.elementsEqual(apps) {
                $0 == $1 && Session.sameID($0.session, $1.session)
            } ?? false
            if !unchanged { try writeJSON(Paths.apps, apps) }
        }
    }
}
