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
    var matchesProcess: Bool {
        guard let start = processBirth(pid) else { return false }
        if let processStart { return start == processStart }
        return Double(start) / 1e6 <= startedAt && isDaemonCommand(pid)
    }
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct ManagedApp: Codable {
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

final class StateLock {
    let fd: Int32

    init(_ name: String, nonblocking: Bool = false) throws {
        try Paths.ensureDirectory(Paths.dir)
        let path = Paths.dir.appendingPathComponent(name).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CLIError("cannot open lock at " + path) }
        while flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            if errno == EINTR { continue }
            let error = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        fd = descriptor
    }

    deinit { close(fd) }
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
    static func read(allowMissing: Bool = true) throws -> [ManagedApp] {
        do {
            let records = try JSONDecoder().decode([ManagedApp].self, from: Data(contentsOf: Paths.apps))
            return records.filter { $0.matchesProcess }
        } catch CocoaError.fileReadNoSuchFile where allowMissing { return [] }
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
            var apps = try read()
            try change(&apps)
            try writeJSON(Paths.apps, apps)
        }
    }
}
