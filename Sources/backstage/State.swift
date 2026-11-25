import Foundation
import AppKit

/// Shared state between the CLI and the daemon lives in ~/.backstage as small JSON files.
enum Paths {
    static let dir: URL = {
        if let o = ProcessInfo.processInfo.environment["BACKSTAGE_HOME"] { return URL(fileURLWithPath: o) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".backstage")
    }()
    /// BACKSTAGE_HOME unset or naming ~/.backstage itself.
    static var isDefaultHome: Bool {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".backstage")
        return dir.resolvingSymlinksInPath().standardizedFileURL.path == standard.resolvingSymlinksInPath().standardizedFileURL.path
    }
    static var daemon: URL { dir.appendingPathComponent("daemon.json") }
    static var apps: URL { dir.appendingPathComponent("apps.json") }
    static var log: URL { dir.appendingPathComponent("daemon.log") }
    static var shots: URL { dir.appendingPathComponent("shots") }
    static var wrappers: URL { dir.appendingPathComponent("wrappers") }
    static var appLogs: URL { dir.appendingPathComponent("logs") }
    static var requests: URL { dir.appendingPathComponent("requests") }
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
        for d in [dir, shots, wrappers, appLogs, requests] { try ensureDirectory(d) }
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
    /// The Send Front Window Backstage hotkey the daemon holds (canonical spec), and why it
    /// couldn't register the one settings.json asks for. Both nil: none asked for.
    var hotkey: String? = nil
    var hotkeyError: String? = nil
    /// The settings.json stamp (`settingsStamp()`) the daemon last applied; absent in daemons
    /// from before settings.
    var settingsApplied: String? = nil

    /// Every display this daemon runs, the primary first (phase 2 of docs/MULTI_DISPLAY_PLAN.md).
    /// The top-level displayID and bounds are the primary's.
    var displays: [DisplayEntry]? = nil

    /// 3: several displays per daemon (`displays`, ManagedApp/LaunchRecord `display`).
    static let currentProtocol = 3
    var protocolMismatch: Bool { (self.protocol ?? 1) != DaemonInfo.currentProtocol }
    var matchesProcess: Bool {
        guard let start = processBirth(pid) else { return false }
        if let processStart { return start == processStart }
        return Double(start) / 1e6 <= startedAt && isDaemonCommand(pid)
    }
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// The primary display's slot (1 for the default home).
    var primarySlot: Int { displays?.first?.slot ?? displaySlot(serial: CGDisplaySerialNumber(displayID)) ?? 1 }
    func entry(_ slot: Int) -> DisplayEntry? { displays?.first { $0.slot == slot } }

    /// This info as seen from one of its displays: displayID and bounds are that display's, so
    /// every coordinate, crop and placement computed from it is relative to that display.
    /// Nil if the daemon doesn't run that display.
    func on(_ slot: Int?) -> DaemonInfo? {
        guard let slot, slot != primarySlot else { return self }
        guard let e = entry(slot) else { return nil }
        var v = self
        v.displayID = e.displayID
        v.x = e.x; v.y = e.y; v.width = e.width; v.height = e.height
        return v
    }
}

/// `launch --display` / `move --display`: the CLI asks the daemon for a display (it must create
/// it: a virtual display lives as long as the process that made it), in requests/<id>.json, and
/// the daemon answers in requests/<id>.reply.
struct DisplayRequest: Codable {
    var id: String          // the daemon uses the request's file name instead
    var session: String
    var want: String        // "new", or a slot number
    var at: Double
}
struct DisplayReply: Codable {
    var ok: Bool
    var slot: Int?
    var error: String?
}

/// One of a daemon's displays, as published in daemon.json.
struct DisplayEntry: Codable, Equatable {
    var slot: Int
    var displayID: UInt32
    var x: Double, y: Double, width: Double, height: Double
    /// `launch --display new`: the session it's reserved for, and until when (epoch seconds).
    var reservedBy: String? = nil
    var reservedUntil: Double? = nil
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    func reserved(now: Double = Date().timeIntervalSince1970) -> String? {
        guard let by = reservedBy, let until = reservedUntil, now < until else { return nil }
        return by
    }
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

    /// The display it's on (a slot); nil: the daemon's primary display (records before protocol 3).
    var display: Int? = nil
    var owner: String { session ?? Session.legacy }
    var audioMode: AudioMode { AudioMode(audio) }

    /// LaunchServices may have no application object for a wrapped executable.
    func requestTermination(force: Bool) throws {
        guard matchesProcess else { return }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.processIdentifier == pid, !app.isTerminated {
            let accepted = force ? app.forceTerminate() : app.terminate()
            if !force { return }
            // forceTerminate can report success and leave the process running (seen with
            // xctest): a forced quit always ends with SIGKILL, so `stop` never stalls on it.
            if accepted, waitFor(timeout: 0.5, { self.matchesProcess ? nil : true }) != nil { return }
        }
        guard matchesProcess else { return }
        if kill(pid, force ? SIGKILL : SIGTERM) != 0, errno != ESRCH {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    var matchesProcess: Bool { liveProcessBirth != nil }

    var liveProcessBirth: UInt64? {
        guard let start = processBirth(pid) else { return nil }
        if let processStart { return start == processStart ? start : nil }
        guard Double(start) / 1e6 <= launchedAt,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath(),
              processBirth(pid) == start else { return nil }
        return start
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
          size > 4, size <= bytes.count,
          bytes.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) == 2 else { return false }
    let args = bytes[4..<size].split(separator: 0, maxSplits: 3)
    return args.count >= 3 && args[2].elementsEqual("__daemon".utf8)
        && URL(fileURLWithPath: String(decoding: args[0], as: UTF8.self)).lastPathComponent == "backstage"
}

/// An flock in BACKSTAGE_HOME, held until `release()` or deinit. See `Locks` for the order.
final class StateLock {
    private(set) var fd: Int32

    init(_ name: String, nonblocking: Bool = false, shared: Bool = false, create: Bool = true) throws {
        let url = Paths.dir.appendingPathComponent(name)
        if create { try Paths.ensureDirectory(url.deletingLastPathComponent()) }
        let path = url.path
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0)
        while true {
            let descriptor = open(path, flags, 0o600)
            if descriptor < 0, errno == EINTR { continue }
            guard descriptor >= 0 else { throw CLIError("cannot open lock at " + path) }
            var held = stat(), current = stat()
            guard fstat(descriptor, &held) == 0, held.st_mode & S_IFMT == S_IFREG else {
                close(descriptor)
                throw CLIError("cannot open regular lock file at " + path)
            }
            while flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | (nonblocking ? LOCK_NB : 0)) != 0 {
                if errno == EINTR { continue }
                let error = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            // Lock files of dead apps and old sessions are pruned (unlinked under the lock). If
            // that happened while this waited, the lock is on an orphaned file: start over.
            if lstat(path, &current) == 0 {
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
        try update { apps in
            guard let birth = processBirth(a.pid), a.processStart.map({ $0 == birth }) ?? true,
                  Double(birth) / 1e6 <= a.launchedAt else {
                throw CLIError("managed process exited during launch")
            }
            var app = a
            app.processStart = birth
            apps.removeAll { $0.pid == a.pid }
            apps.append(app)
        }
    }

    static func remove(_ pid: Int32) throws {
        try update { $0.removeAll { $0.pid == pid } }
    }

    static func update(_ change: (inout [ManagedApp]) throws -> Void) throws {
        let lock = try Locks.registry()
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
