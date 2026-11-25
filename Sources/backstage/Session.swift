import Foundation
import CryptoKit

/// The agent session a CLI invocation belongs to. A session owns the apps it launches: its
/// default target, `list`, `logs`, screenshots and `stop` only see those. Ownership routes
/// commands among cooperating agents in one login; it isn't a security boundary.
///
/// Derivation, first match wins:
/// 1. `BACKSTAGE_SESSION=<name>` (scripts, test harnesses, or one agent splitting its subagents).
/// 2. The nearest known agent ancestor (claude, codex, grok…; also `node`/`python`/`bun`/`deno`
///    running one of them, recognised by its arguments), using that agent's own session
///    variable when it sets one in tool shells: `CLAUDE_CODE_SESSION_ID` (checked against
///    `CLAUDE_PID`), `CODEX_THREAD_ID`, `GROK_SESSION_ID`. A variable counts only for the
///    nearest agent and only if that agent didn't itself inherit the same value, so a nested
///    agent that doesn't export its own ID (codex → claude → codex) gets its own session.
/// 3. Otherwise that agent process: name, PID and process start time.
/// 4. No agent, with a controlling terminal (a person, or a script run in a terminal): the
///    terminal session (`getsid`, plus the leader's start time), so each tab or tmux pane is
///    its own session. Agent tool shells are usually session leaders without a terminal, so
///    an unknown agent isn't split into one session per command.
/// 5. Otherwise the nearest non-shell ancestor (PID and start time).
/// 6. Otherwise the outermost shell ancestor: a private session, never a shared default.
/// If the parent has already exited (`backstage … &` from a finished shell, nohup, cron or
/// launchd), there's no chain to walk. A single agent session variable is used as is; otherwise
/// it's an error asking for BACKSTAGE_SESSION. launchd (PID 1) is never a session key.
/// Known limits: Claude Code subagents share their parent's session (Claude gives them no
/// variable of their own), while each Codex subagent has its own CODEX_THREAD_ID (checked live;
/// CODEX_SESSION_ID is shared by a Codex session's subagents, so it isn't used). GROK_SESSION_ID
/// hasn't been checked in a live Grok session. `env -i` or `sudo` drop the variables, so the
/// same Claude session becomes `claude:<pid>-<start>` there.
/// The daemon and the menu bar never derive a session; they act on records' stored owners.
struct Session {
    let id: String
    let source: String

    /// Owner of app records written before sessions existed. Only `--all` forms list or stop
    /// them; an explicit `--pid` can still address them because nobody else owns them.
    static let legacy = "legacy"
    /// Owner of apps the user sent backstage themselves (Send Front Window Backstage). Like
    /// legacy records, any session reaches them with an explicit `--pid` or `--app`, but they're
    /// never a session's default target and only `stop --all` (or the menu) quits them.
    static let user = "user"

    /// The app was sent backstage by the user, not launched by an agent.
    static func isUser(_ owner: String?) -> Bool { sameID(owner, user) }

    private static let cached = Result { try derive(ProcessInfo.processInfo.environment) }
    static func current() throws -> Session {
        try cached.get()
    }

    /// A file-name-safe key for this session's lock and screenshot folder.
    static func fileKey(_ id: String) -> String {
        let safe = String(id.unicodeScalars.prefix(40).map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) ? Character($0) : "_"
        })
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe)-\(hash)"
    }

    /// Session IDs use their original UTF-8 spelling, as do the existing lock filenames.
    static func sameID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func derive(_ env: [String: String]) throws -> Session {
        if let name = env["BACKSTAGE_SESSION"], !name.isEmpty {
            guard name != legacy else { throw CLIError("BACKSTAGE_SESSION=legacy is reserved for apps launched before sessions existed") }
            guard !isUser(name) else { throw CLIError("BACKSTAGE_SESSION=user is reserved for apps the user sent backstage") }
            guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CLIError("BACKSTAGE_SESSION must not contain control characters")
            }
            return Session(id: name, source: "BACKSTAGE_SESSION")
        }
        func variable(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        let chain = ancestors()
        guard !chain.isEmpty else {
            // Reparented to launchd: every detached caller would share a launchd-based key.
            let found = sessionVariables.compactMap { v in variable(v.key).map { (v, $0) } }
            if found.count == 1, let (v, id) = found.first { return Session(id: v.kind + ":" + id, source: v.key) }
            let why = found.isEmpty ? "" : " Several agent session variables are set (\(found.map { $0.0.key }.joined(separator: ", "))), so which one applies is unclear."
            throw CLIError("can't work out the backstage session: the calling process's parent has exited (detached with &/nohup/setsid, or run by cron/launchd).\(why) Set BACKSTAGE_SESSION=<name> on each command.")
        }
        if let agent = nearestAgent(chain), let kind = agent.agent {
            // Trust the variable only if this agent set it: a value the agent itself inherited
            // came from an outer agent. Unreadable environments (another user) are trusted.
            func own(_ key: String) -> String? {
                guard let id = variable(key) else { return nil }
                return processEnvironmentValue(agent.pid, key: key) == id ? nil : id
            }
            if let v = sessionVariables.first(where: { $0.kind == kind }), let id = own(v.key),
               v.key != "CLAUDE_CODE_SESSION_ID" || env["CLAUDE_PID"].map({ Int32($0) == agent.pid }) ?? true {
                return Session(id: kind + ":" + id, source: v.key)
            }
            return Session(id: "\(kind):\(agent.pid)-\(agent.birth)", source: "agent process")
        }
        let sid = getsid(0)
        if hasControllingTerminal(), sid > 1, sid != getpid(), let birth = processBirth(sid) {
            return Session(id: "tty:\(sid)-\(birth)", source: "terminal session")
        }
        if let other = chain.first(where: { !$0.skipped }) {
            return Session(id: "\(other.name):\(other.pid)-\(other.birth)", source: "parent process")
        }
        let top = chain[chain.count - 1]
        return Session(id: "process:\(top.pid)-\(top.birth)", source: "calling process")
    }

    /// Each agent's own session variable, as its tool shells see it.
    static let sessionVariables: [(kind: String, key: String)] = [
        ("claude", "CLAUDE_CODE_SESSION_ID"), ("codex", "CODEX_THREAD_ID"), ("grok", "GROK_SESSION_ID"),
    ]
    static let knownAgents = ["claude", "codex", "grok", "cursor-agent", "gemini", "opencode", "aider", "amp", "goose"]
    /// Runtimes that npm/pip-installed agents run under; their arguments name the agent.
    static let interpreters = ["node", "python", "bun", "deno"]
    static let skippedProcesses: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "env", "sudo", "login", "nohup", "timeout",
                                                "xargs", "make", "gmake", "script", "tmux", "screen", "backstage", "herdr-zsh"]

    struct Ancestor {
        let pid: pid_t
        let birth: UInt64
        let name: String
        let agent: String?
        var skipped: Bool { Session.skippedProcesses.contains(name) || name.hasPrefix("-") }
    }

    static func agentName(_ word: String) -> String? {
        let n = word.lowercased()
        return knownAgents.first { n == $0 || n.hasPrefix($0 + "-") || n.hasPrefix($0 + ".") }
    }

    /// The agent an interpreter runs: a path component of one of its first arguments
    /// (`node …/bin/gemini`, `node …/@anthropic-ai/claude-code/cli.js`, `python -m aider`).
    static func interpretedAgent(_ pid: pid_t) -> String? {
        guard let argv = processArguments(pid, includeEnvironment: false)?.argv else { return nil }
        for arg in argv.dropFirst().prefix(4) where !arg.hasPrefix("-") {
            if let agent = arg.split(separator: "/").lazy.compactMap({ agentName(String($0)) }).first { return agent }
        }
        return nil
    }

    /// The closest ancestor that is an agent; the scan stops there.
    static func nearestAgent(_ chain: [Ancestor]) -> Ancestor? { chain.first { $0.agent != nil } }

    /// Parent processes from the caller up to the nearest agent or launchd.
    static func ancestors() -> [Ancestor] {
        var chain: [Ancestor] = []
        var pid = getppid()
        for _ in 0..<32 {
            guard pid > 1 else { break }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { break }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let n = (name.isEmpty ? comm : name).lowercased()
            var agent = agentName(n)
            if agent == nil, interpreters.contains(where: { n == $0 || n.hasPrefix($0 + "3") || n.hasPrefix($0 + "-") }) {
                agent = interpretedAgent(pid)
            }
            chain.append(Ancestor(pid: pid, birth: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, name: n, agent: agent))
            if agent != nil { break }
            pid = pid_t(info.pbi_ppid)
        }
        return chain
    }

    static func hasControllingTerminal() -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        return proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0
    }
}

/// A process's arguments and environment, from KERN_PROCARGS2: argc, the executable path,
/// alignment padding, argv, then the environment. Nil if unreadable (another user's process).
private func readProcessArguments(_ pid: pid_t, decodeArguments: Bool) -> (argv: [String], environment: ArraySlice<UInt8>)? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0,
          size > MemoryLayout<Int32>.size, size <= bytes.count else { return nil }
    let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = MemoryLayout<Int32>.size
    guard argc > 0, let endOfPath = bytes[index..<size].firstIndex(of: 0) else { return nil }
    index = endOfPath
    while index < size && bytes[index] == 0 { index += 1 }
    var argv: [String] = []
    for _ in 0..<argc {
        guard let end = bytes[index..<size].firstIndex(of: 0) else { return nil }
        if decodeArguments { argv.append(String(decoding: bytes[index..<end], as: UTF8.self)) }
        index = end + 1
    }
    return (argv, bytes[index..<size])
}

func processArguments(_ pid: pid_t, includeEnvironment: Bool = true) -> (argv: [String], env: [String: String])? {
    guard let (argv, bytes) = readProcessArguments(pid, decodeArguments: true) else { return nil }
    if !includeEnvironment { return (argv, [:]) }
    var index = bytes.startIndex
    let size = bytes.endIndex
    var env: [String: String] = [:]
    while index < size && bytes[index] != 0 {
        guard let end = bytes[index..<size].firstIndex(of: 0) else { break }
        let entry = String(decoding: bytes[index..<end], as: UTF8.self)
        if let eq = entry.firstIndex(of: "="), env[String(entry[..<eq])] == nil {
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        index = end + 1
    }
    return (argv, env)
}

/// Read a single environment value without decoding the process's arguments or other variables.
func processEnvironmentValue(_ pid: pid_t, key: String) -> String? {
    guard let bytes = readProcessArguments(pid, decodeArguments: false)?.environment else { return nil }
    let prefix = (key + "=").utf8
    var start = bytes.startIndex
    while start < bytes.endIndex && bytes[start] != 0 {
        guard let end = bytes[start...].firstIndex(of: 0) else { return nil }
        let entry = bytes[start..<end]
        if entry.starts(with: prefix) { return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self) }
        start = end + 1
    }
    return nil
}

/// Coordination locks in BACKSTAGE_HOME. Acquire in this order, never the reverse:
///   client.lock → lifecycle.lock → locks/session-<id> → locks/app-<pid>-<birth> → lock (registry)
/// - client.lock: daemon start/stop transitions (one starter at a time; no launch while
///   `stop` is waiting for the daemon to exit).
/// - lifecycle.lock: launches hold it shared from daemon start until their app is registered;
///   daemon shutdown and the last `stop` take it exclusively, so the daemon never quits or
///   disappears while a launch it can't see yet is in flight.
/// - locks/session-<id>: a session's launch registration, quit and stop.
/// - locks/app-<pid>-<birth>: a whole input command (focus plus every event) for one app.
/// - lock: reads and writes of apps.json.
enum Locks {
    static func session(_ id: String, nonblocking: Bool = false) throws -> StateLock {
        try StateLock("locks/session-" + Session.fileKey(id), nonblocking: nonblocking)
    }
    static func app(_ app: ManagedApp, nonblocking: Bool = false) throws -> StateLock {
        try StateLock("locks/app-\(app.pid)-\(app.processStart ?? 0)", nonblocking: nonblocking)
    }
    static func registry(nonblocking: Bool = false) throws -> StateLock {
        try StateLock("lock", nonblocking: nonblocking)
    }
    /// Remove lock files of apps that are gone. Nobody can hold a dead app's lock usefully.
    /// Records without a start time lock `app-<pid>-0`, which can't be checked: those stay.
    /// StateLock re-checks the path after locking, so unlinking a lock file is safe.
    static func pruneAppLocks() {
        let dir = Paths.dir.appendingPathComponent("locks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("app-") {
            let parts = name.dropFirst(4).split(separator: "-")
            guard parts.count == 2, let pid = pid_t(parts[0]), pid > 0,
                  let birth = UInt64(parts[1]), birth != 0,
                  processBirth(pid) != birth,
                  let lock = try? StateLock("locks/" + name, nonblocking: true, create: false) else { continue }
            unlink(dir.appendingPathComponent(name).path)
            lock.release()
        }
    }

    /// Remove lock files of sessions that have no apps or launches and haven't stopped or
    /// launched for a day. A session's lock file holds its last `stop` time, which a launch
    /// started before that stop reads; no launch runs anywhere near a day, so dropping it then
    /// loses nothing. Each file is unlinked while holding its lock (non-blocking: skip if busy).
    static func pruneSessionLocks() {
        let dir = Paths.dir.appendingPathComponent("locks")
        let cutoff = Date().addingTimeInterval(-86_400)
        func isOld(_ url: URL) -> Bool {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                return false
            }
            return modified < cutoff
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let candidates = names.filter { $0.hasPrefix("session-") && isOld(dir.appendingPathComponent($0)) }
        guard !candidates.isEmpty, let apps = try? AppStore.read() else { return }
        let owners = apps.map { $0.owner } + Launching.records().map { $0.session }
        let distinctOwners = Set(owners.map { Data($0.utf8) })
        let live = Set(distinctOwners.map { "session-" + Session.fileKey(String(decoding: $0, as: UTF8.self)) })
        for name in candidates where !live.contains(name) {
            let url = dir.appendingPathComponent(name)
            guard let lock = try? StateLock("locks/" + name, nonblocking: true, create: false) else { continue }
            // A stop may have written a new stamp after the directory scan.
            if isOld(url) { unlink(url.path) }
            lock.release()
        }
    }
}
