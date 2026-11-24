import Foundation
import AppKit

/// A launch in flight. `launch` writes one before opening the app and removes it once the app is
/// registered (or nothing was started). If the CLI dies in between (an agent's tool timeout,
/// Ctrl-C), the app it started belongs to no session. The daemon then finds that app from
/// this record, quits it, and drops the record. If instead the CLI gave up waiting for the app
/// to appear (`handedOver`), the daemon registers the app to the launch's session when it turns
/// up (see reapOrphanLaunches). While any record exists the daemon isn't idle.
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
    /// The agent that ran `launch` (ManagedApp.agent), for an app the daemon registers.
    var agent: String? = nil
    var agentPID: Int32? = nil
    /// When the CLI started the operation, before it acquired its daemon or submitted the open.
    var commandStartedAt: Double? = nil
    var forcedInaudible: Bool? = nil
    /// Set by a `launch` that gave up because the app's process hadn't appeared in time: the
    /// daemon registers the app to `session` if it turns up later, instead of quitting it.
    var handedOver: Bool? = nil
    /// The display the app goes on (a slot); nil: the primary display.
    var display: Int? = nil

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

    /// How long the daemon keeps a handed-over record whose app hasn't appeared, from the
    /// launch's start. LaunchServices has been seen to start an app long after it was asked to
    /// during a WindowServer stall.
    static let handOverWindow: Double = 600

    /// How long `launch` waits for the app's process to appear (independent of --timeout, the
    /// first-window wait): `total` from the open request, and at most `afterAnswer` once
    /// LaunchServices has answered (it reports the PID, so identification is then immediate
    /// unless the process can't be recognised, e.g. a script). Longer under heavy load (1-minute
    /// load average above the CPU count), when LaunchServices can take tens of seconds to
    /// answer. BACKSTAGE_LAUNCH_DEADLINE sets `total` in seconds.
    static func deadlines() -> (total: Double, afterAnswer: Double, heavyLoad: Bool) {
        var load = [Double](repeating: 0, count: 1)
        let heavy = getloadavg(&load, 1) == 1 && load[0] > Double(ProcessInfo.processInfo.activeProcessorCount)
        var total: Double = heavy ? 120 : 60
        if let value = ProcessInfo.processInfo.environment["BACKSTAGE_LAUNCH_DEADLINE"],
           let seconds = Double(value), seconds.isFinite, seconds >= 0 { total = seconds }
        return (total, min(total, heavy ? 30 : 15), heavy)
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

    /// The executable the bundle's process runs: the bare executable, or CFBundleExecutable.
    var processExecutable: URL? { executable ?? Bundle(url: bundle)?.executableURL }

    /// The new process: an instance of the bundle carrying this launch's token or log (for a
    /// bare executable, also running that executable), found by the PID in the receipt when there
    /// is one. `isNew` filters out processes that existed before the launch.
    func find(isNew: (pid_t) -> Bool) -> (app: NSRunningApplication?, pid: pid_t, birth: UInt64)? {
        if executable != nil, let reported = receiptPID() {
            guard reported > 0, isNew(reported) else { return nil }
            return verify(reported)
        }
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard isNew(pid), !app.isTerminated,
                  app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundle else { continue }
            if let found = verify(pid, app: app, bundleMatches: true) { return found }
        }
        // Not (yet) a registered application: LaunchServices can lag far behind the process it
        // started under heavy load, or never check it in. Look through every process for the one
        // running the app's executable with this launch's token or log. Its children (test
        // runners re-exec themselves) inherit both, so take the oldest.
        guard let exe = processExecutable else { return nil }
        var expected = stat()
        guard stat(exe.path, &expected) == 0 else { return nil }
        var oldest: (app: NSRunningApplication?, pid: pid_t, birth: UInt64)?
        for pid in allProcessIDs() where isNew(pid) && runs(pid, expected) {
            if let found = verify(pid), found.birth < oldest?.birth ?? .max { oldest = found }
        }
        return oldest
    }

    /// `pid` is this launch's process: it carries the token or owns the log (and, for a bare
    /// executable, runs it). The receipt, when there is one, names it.
    func verify(_ pid: pid_t) -> (app: NSRunningApplication?, pid: pid_t, birth: UInt64)? {
        verify(pid, app: NSRunningApplication(processIdentifier: pid), bundleMatches: false)
    }

    private func verify(_ pid: pid_t, app candidate: NSRunningApplication?,
                        bundleMatches: Bool) -> (app: NSRunningApplication?, pid: pid_t, birth: UInt64)? {
        guard let birth = processBirth(pid) else { return nil }
        let app = candidate.flatMap { $0.processIdentifier == pid && !$0.isTerminated ? $0 : nil }
        if let target = executable {
            guard receiptPID().map({ $0 == pid }) ?? true, matchesExecutable(pid, target) else { return nil }
        } else if !(bundleMatches || app?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundle) {
            // No application object yet (LaunchServices hasn't checked it in): the process runs
            // the bundle's executable.
            guard let exe = processExecutable, matchesExecutable(pid, exe) else { return nil }
        }
        guard ownsLog(pid) || hasLaunchToken(pid, assignment: assignment),
              processBirth(pid) == birth else { return nil }
        return (app, pid, birth)
    }
}

private func matchesExecutable(_ pid: pid_t, _ target: URL) -> Bool {
    var expected = stat()
    return stat(target.path, &expected) == 0 && runs(pid, expected)
}

/// The process's executable is the file `expected` describes.
private func runs(_ pid: pid_t, _ expected: stat) -> Bool {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var actual = stat()
    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && stat(path, &actual) == 0 &&
        actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
}

/// Every process ID on the system.
func allProcessIDs() -> [pid_t] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
}

/// The process's environment holds exactly `assignment` (NAME=value).
func hasLaunchToken(_ pid: pid_t, assignment: String) -> Bool {
    guard let eq = assignment.firstIndex(of: "="), let env = processArguments(pid)?.env else { return false }
    return env[String(assignment[..<eq])] == String(assignment[assignment.index(after: eq)...])
}

/// Settle launches whose CLI is gone without registering their app, and drop their records once
/// that's done or nothing appeared within a grace period. Run by the daemon (on its timer).
/// - The CLI died (an agent's tool timeout, Ctrl-C): quit the app; grace period 15 s after the
///   CLI died, at least 30 s after the launch started.
/// - The CLI gave up waiting for the process (`handedOver`): register the app to the launch's
///   session (or quit it if the session ran `stop` since); grace period `handOverWindow`.
/// `final` (shutdown, with no launch able to run) takes every record now, with no grace period,
/// and quits everything. `registered` tells apps that made it into the registry; `didRegister`
/// is told about apps this registered. Returns the processes it quit.
@discardableResult
func reapOrphanLaunches(deadSince: inout [String: Double], registered: (pid_t, UInt64) -> Bool,
                        final: Bool = false, didRegister: (pid_t, UInt64) -> Void = { _, _ in },
                        log: (String) -> Void) -> [pid_t] {
    let now = Date().timeIntervalSince1970
    var quit: [pid_t] = []
    let records = Launching.records()
    let recordIDs = Set(records.map(\.id))
    deadSince = deadSince.filter { recordIDs.contains($0.key) }
    for record in records where final || !record.cliAlive {
        let died = deadSince[record.id] ?? now
        deadSince[record.id] = died
        let handedOver = record.handedOver == true && !final
        let found = record.target?.find { pid in
            processBirth(pid).map { Double($0) / 1e6 >= record.startedAt - 1 } ?? false
        }
        if let (app, pid, birth) = found {
            if !registered(pid, birth), processBirth(pid) == birth {
                var why = "its launch (\(record.id)) ended before registering it"
                if handedOver {
                    switch registerHandedOver(record, pid: pid, birth: birth) {
                    case .busy: continue   // the session is mid-`stop` or mid-launch: next pass
                    case .registered:
                        log("registered pid \(pid) to session \(record.session): its launch (\(record.id)) gave up waiting for it")
                        didRegister(pid, birth)
                        why = ""
                    case .gone: why = ""
                    case .stopped: why = "its session ran `stop` after its launch (\(record.id)) started"
                    case .refused(let reason): why = reason
                    }
                }
                if !why.isEmpty {
                    log("quitting pid \(pid): \(why)")
                    if app?.forceTerminate() != true, processBirth(pid) == birth { _ = kill(pid, SIGKILL) }
                    quit.append(pid)
                }
            }
        } else if handedOver {
            guard now - record.startedAt >= Launching.handOverWindow else { continue }
            log("dropping launch \(record.id): no process appeared within \(Int(Launching.handOverWindow))s")
        } else if !final && (now - died < 15 || now - record.startedAt < 30) {
            continue   // `open` may still be starting the app
        }
        Launching.end(record.id)
        try? FileManager.default.removeItem(at: record.receipt)
        deadSince[record.id] = nil
    }
    return quit
}

enum HandOverOutcome { case registered, stopped, refused(String), busy, gone }

/// Register the app of a handed-over launch to its session, as `launch` would have: same record,
/// same lock order (session, app, registry). `.stopped` when the session ran `stop` after the
/// launch started (quit it instead), `.busy` when the session's lock is held (try again later).
/// Its sound: the tap manager tapped it on sight by its launch token; inaudible only if the
/// injected library confirmed (as `launch` checks), else muted. Its windows: the daemon moves
/// them to the agent display and then unhides the app (Daemon.revealRegistered).
func registerHandedOver(_ launch: LaunchRecord, pid: pid_t, birth: UInt64) -> HandOverOutcome {
    let owner: StateLock
    do { owner = try Locks.session(launch.session, nonblocking: true) } catch { return .busy }
    defer { owner.release() }
    do {
        if let stopped = try owner.readStamp(), stopped >= (launch.commandStartedAt ?? launch.startedAt) { return .stopped }
    } catch {
        return .refused("couldn't read its session's stop time: \(error)")
    }
    let url = URL(fileURLWithPath: launch.bundle)
    let bundle = Bundle(url: url)
    var mode = AudioMode(launch.audio)
    let ack = InaudibleLibrary.ackFile(launch.id)
    if mode == .inaudible {
        let parts = ((try? String(contentsOf: ack, encoding: .utf8)) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" })
        let status = parts.count >= 2 && pid_t(parts[0]) == pid ? Int32(parts[1]) : nil
        let confirmed: Bool = status.map { $0 == 0 }
            ?? InaudibleLibrary.locate().map { processMaps(pid, $0) }
            ?? false
        if !confirmed {
            if launch.forcedInaudible == true {
                try? FileManager.default.removeItem(at: ack)
                return .refused("couldn't confirm that its launch (\(launch.id)) made it inaudible")
            }
            mode = .muted
        }
    }
    let record = ManagedApp(pid: pid, name: (bundle?.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
                            bundleID: bundle?.bundleIdentifier, path: launch.bundle, launchedAt: Date().timeIntervalSince1970,
                            stdout: launch.log, processStart: birth, agent: launch.agent, agentPID: launch.agentPID,
                            session: launch.session, audio: mode.rawValue, display: launch.display)
    do { try AppStore.add(record) } catch { return processBirth(pid) == birth ? .busy : .gone }
    try? FileManager.default.removeItem(at: ack)
    return .registered
}
