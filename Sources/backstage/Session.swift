import Foundation
import CryptoKit

/// The agent session a CLI invocation belongs to. A session owns the apps it launches: its
/// default target, `list`, `logs`, screenshots and `stop` only see those. Ownership routes
/// commands among cooperating agents in one login; it isn't a security boundary.
///
/// Derivation, first match wins:
/// 1. `BACKSTAGE_SESSION=<name>` (scripts, test harnesses, or one agent splitting its subagents).
/// 2. The nearest known agent ancestor (claude, codex, grok…), using that agent's own session
///    variable when it sets one in tool shells: `CLAUDE_CODE_SESSION_ID` (checked against
///    `CLAUDE_PID`), `CODEX_THREAD_ID`, `GROK_SESSION_ID`. Variables are only trusted for the
///    nearest agent, so a nested agent doesn't inherit its parent's session.
/// 3. Otherwise that agent process: name, PID and process start time.
/// 4. Otherwise the nearest non-shell ancestor (PID and start time).
/// 5. Otherwise the outermost shell ancestor: a private session, never a shared default.
/// The daemon and the menu bar never derive a session; they act on records' stored owners.
struct Session {
    let id: String
    let source: String

    /// Owner of app records written before sessions existed. Only `--all` forms list or stop
    /// them; an explicit `--pid` can still address them because nobody else owns them.
    static let legacy = "legacy"

    private static var cached: Session?
    static func current() throws -> Session {
        if let cached { return cached }
        let session = try derive(ProcessInfo.processInfo.environment)
        cached = session
        return session
    }

    /// A file-name-safe key for this session's lock and screenshot folder.
    static func fileKey(_ id: String) -> String {
        let safe = String(id.unicodeScalars.prefix(40).map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) ? Character($0) : "_"
        })
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe)-\(hash)"
    }

    static func derive(_ env: [String: String]) throws -> Session {
        if let name = env["BACKSTAGE_SESSION"], !name.isEmpty {
            guard name != legacy else { throw CLIError("BACKSTAGE_SESSION=legacy is reserved for apps launched before sessions existed") }
            guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CLIError("BACKSTAGE_SESSION must not contain control characters")
            }
            return Session(id: name, source: "BACKSTAGE_SESSION")
        }
        let chain = ancestors()
        if let agent = chain.first(where: { $0.agent != nil }), let kind = agent.agent {
            func variable(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
            switch kind {
            case "claude":
                if let id = variable("CLAUDE_CODE_SESSION_ID"), env["CLAUDE_PID"].map({ Int32($0) == agent.pid }) ?? true {
                    return Session(id: "claude:" + id, source: "CLAUDE_CODE_SESSION_ID")
                }
            case "codex":
                if let id = variable("CODEX_THREAD_ID") { return Session(id: "codex:" + id, source: "CODEX_THREAD_ID") }
            case "grok":
                if let id = variable("GROK_SESSION_ID") { return Session(id: "grok:" + id, source: "GROK_SESSION_ID") }
            default: break
            }
            return Session(id: "\(kind):\(agent.pid)-\(agent.birth)", source: "agent process")
        }
        if let other = chain.first(where: { !$0.skipped }) {
            return Session(id: "\(other.name):\(other.pid)-\(other.birth)", source: "parent process")
        }
        if let top = chain.last {
            return Session(id: "process:\(top.pid)-\(top.birth)", source: "calling process")
        }
        let me = getppid()
        return Session(id: "process:\(me)-\(processBirth(me) ?? 0)", source: "calling process")
    }

    static let knownAgents = ["claude", "codex", "grok", "cursor-agent", "gemini", "opencode", "aider", "amp", "goose"]
    static let skippedProcesses: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "env", "sudo", "login", "nohup", "timeout",
                                                "xargs", "make", "gmake", "script", "tmux", "screen", "backstage", "herdr-zsh"]

    struct Ancestor {
        let pid: pid_t
        let birth: UInt64
        let name: String
        let agent: String?
        var skipped: Bool { Session.skippedProcesses.contains(name) || name.hasPrefix("-") }
    }

    /// Parent processes from the caller up to (not including) launchd.
    static func ancestors() -> [Ancestor] {
        var chain: [Ancestor] = []
        var pid = getppid()
        for _ in 0..<32 {
            guard pid > 1 else { break }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let n = (name.isEmpty ? comm : name).lowercased()
            let agent = knownAgents.first { n == $0 || n.hasPrefix($0 + "-") || n.hasPrefix($0 + ".") }
            chain.append(Ancestor(pid: pid, birth: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, name: n, agent: agent))
            pid = pid_t(info.pbi_ppid)
        }
        return chain
    }
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
    static func app(_ app: ManagedApp) throws -> StateLock {
        try StateLock("locks/app-\(app.pid)-\(app.processStart ?? 0)")
    }
    /// Remove lock files of apps that are gone. Nobody can hold a dead app's lock usefully.
    static func pruneAppLocks() {
        let dir = Paths.dir.appendingPathComponent("locks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("app-") {
            let parts = name.dropFirst(4).split(separator: "-")
            guard parts.count == 2, let pid = pid_t(parts[0]), let birth = UInt64(parts[1]) else { continue }
            if processBirth(pid) != birth { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }
}
