import Foundation
import AppKit

/// A launch in flight. `launch` writes one before opening the app and removes it once the app is
/// registered (or nothing was started). If the CLI dies in between (an agent's tool timeout,
/// Ctrl-C), the app it started belongs to no session. The daemon then finds that app from
/// this record, quits it, and drops the record. While any record exists the daemon isn't idle.
struct LaunchRecord: Codable {
    var id: String              // BACKSTAGE_LAUNCH_ID
    var session: String
    var cliPID: Int32
    var cliStart: UInt64
    var bundle: String          // the .app opened (the wrapper, for a bare executable)
    var executable: String?     // the bare executable, if any
    var log: String
    var startedAt: Double
    /// AudioMode: the tap manager taps the app on sight, before registration, and measures it
    /// only when metered. Absent in records from before modes (and hand-written test records): metered.
    var audio: String? = nil

    var cliAlive: Bool { processBirth(cliPID) == cliStart }
    var receipt: URL { Paths.appLogs.appendingPathComponent("\(id).pid") }

    var target: LaunchTarget? {
        var metadata = stat()
        guard stat(log, &metadata) == 0 else { return nil }
        return LaunchTarget(bundle: URL(fileURLWithPath: bundle).resolvingSymlinksInPath().standardizedFileURL,
                            executable: executable.map { URL(fileURLWithPath: $0) }, launchID: id,
                            logDevice: metadata.st_dev, logInode: metadata.st_ino, receipt: receipt)
    }
}

enum Launching {
    static var dir: URL { Paths.dir.appendingPathComponent("launching") }
    static func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    static func begin(_ record: LaunchRecord) throws {
        try Paths.ensureDirectory(dir)
        try writeJSON(file(record.id), record)
    }

    static func end(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }

    static func records() -> [LaunchRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { readJSON(dir.appendingPathComponent($0), LaunchRecord.self) }
    }
}

/// What identifies the process a launch started.
struct LaunchTarget {
    let bundle: URL             // resolved, standardized
    let executable: URL?
    let launchID: String
    let logDevice: dev_t
    let logInode: ino_t
    let receipt: URL

    var assignment: String { "BACKSTAGE_LAUNCH_ID=\(launchID)" }

    /// stdout or stderr is this launch's log file.
    func ownsLog(_ pid: pid_t) -> Bool {
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            var detail = vnode_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: detail))
            if proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEINFO, &detail, size) == size,
               detail.pvi.vi_stat.vst_ino == logInode,
               detail.pvi.vi_stat.vst_dev == UInt32(bitPattern: logDevice) { return true }
        }
        return false
    }

    func receiptPID() -> pid_t? {
        guard let value = try? String(contentsOf: receipt, encoding: .utf8) else { return nil }
        return pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The new process: an instance of the bundle carrying this launch's token or log (for a
    /// bare executable, also running that executable), found by the PID in the receipt when there
    /// is one. `isNew` filters out processes that existed before the launch.
    func find(isNew: (pid_t) -> Bool) -> (app: NSRunningApplication?, pid: pid_t, birth: UInt64)? {
        if executable != nil, let reported = receiptPID() {
            guard reported > 0, isNew(reported) else { return nil }
            return verify(reported)
        }
        let candidate = NSWorkspace.shared.runningApplications.first {
            isNew($0.processIdentifier) && !$0.isTerminated
                && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundle
                && (ownsLog($0.processIdentifier) || hasLaunchToken($0.processIdentifier, assignment: assignment))
        }
        return candidate.flatMap { verify($0.processIdentifier) }
    }

    /// `pid` is this launch's process: it carries the token or owns the log (and, for a bare
    /// executable, runs it). The receipt, when there is one, names it.
    func verify(_ pid: pid_t) -> (app: NSRunningApplication?, pid: pid_t, birth: UInt64)? {
        guard let birth = processBirth(pid) else { return nil }
        let candidate = NSRunningApplication(processIdentifier: pid)
        let app = candidate.flatMap { $0.processIdentifier == pid && !$0.isTerminated ? $0 : nil }
        guard ownsLog(pid) || hasLaunchToken(pid, assignment: assignment) else { return nil }
        if let target = executable {
            guard receiptPID().map({ $0 == pid }) ?? true, matchesExecutable(pid, target) else { return nil }
        } else if app == nil || app?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL != bundle { return nil }
        guard processBirth(pid) == birth else { return nil }
        return (app, pid, birth)
    }
}

private func matchesExecutable(_ pid: pid_t, _ target: URL) -> Bool {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var expected = stat(), actual = stat()
    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 &&
        stat(target.path, &expected) == 0 && stat(path, &actual) == 0 &&
        actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
}

/// The process's environment holds exactly `assignment` (NAME=value).
func hasLaunchToken(_ pid: pid_t, assignment: String) -> Bool {
    guard let eq = assignment.firstIndex(of: "="), let env = processArguments(pid)?.env else { return false }
    return env[String(assignment[..<eq])] == String(assignment[assignment.index(after: eq)...])
}

/// Quit the apps of launches whose CLI died before registering them, and drop their records
/// once that's done or nothing appeared within a grace period. Run by the daemon (on its
/// timer). `final` (shutdown, with no launch able to run) takes every record now, with no grace
/// period. `registered` tells apps that made it into the registry. Returns the processes it quit.
@discardableResult
func reapOrphanLaunches(deadSince: inout [String: Double], registered: (pid_t, UInt64) -> Bool,
                        final: Bool = false, log: (String) -> Void) -> [pid_t] {
    let now = Date().timeIntervalSince1970
    var quit: [pid_t] = []
    let records = Launching.records()
    deadSince = deadSince.filter { id, _ in records.contains { $0.id == id } }
    for record in records where final || !record.cliAlive {
        let died = deadSince[record.id] ?? now
        deadSince[record.id] = died
        let found = record.target?.find { pid in
            processBirth(pid).map { Double($0) / 1e6 >= record.startedAt - 1 } ?? false
        }
        if let (app, pid, birth) = found {
            if !registered(pid, birth) {
                log("quitting pid \(pid): its launch (\(record.id)) ended before registering it")
                if let app, !app.isTerminated { _ = app.forceTerminate() } else { _ = kill(pid, SIGKILL) }
                quit.append(pid)
            }
        } else if !final && (now - died < 15 || now - record.startedAt < 30) {
            continue   // `open` may still be starting the app
        }
        Launching.end(record.id)
        try? FileManager.default.removeItem(at: record.receipt)
        deadSince[record.id] = nil
    }
    return quit
}
