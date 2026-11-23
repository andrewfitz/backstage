import Foundation
import AppKit
import ApplicationServices

// MARK: - PreToolUse hook

/// Shell tools across agents: Claude `Bash`, Codex `exec_command`/`shell`/`local_shell`,
/// Grok `Bash`/`run_terminal_command`, Cursor `Shell`.
let shellToolNames: Set<String> = ["Bash", "exec_command", "shell", "local_shell", "run_terminal_command", "run_terminal_cmd", "Shell"]

/// Pull the shell command out of a hook payload (snake_case or camelCase; string or argv array).
func hookCommand(_ payload: [String: Any]) -> String? {
    let tool = (payload["tool_name"] ?? payload["toolName"]) as? String ?? ""
    guard shellToolNames.contains(tool), let input = (payload["tool_input"] ?? payload["toolInput"]) as? [String: Any] else { return nil }
    for key in ["command", "cmd"] {
        if let s = input[key] as? String { return s }
        if let a = input[key] as? [String] {
            // ["bash", "-lc", "<script>"] → the script; otherwise the joined argv.
            if a.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(a[0]), a[1].hasSuffix("c") { return a[2] }
            return a.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        }
    }
    return nil
}

/// Split a shell string into simple-command word lists. Handles quotes, escapes and the
/// usual separators. It isn't a full shell parser, but it doesn't need to be.
func shellSegments(_ s: String) -> [[String]] {
    var segments: [[String]] = [], words: [String] = [], cur = "", inWord = false
    var quote: Character? = nil
    var it = Array(s), i = 0
    func endWord() { if inWord { words.append(cur); cur = ""; inWord = false } }
    func endSeg() { endWord(); if !words.isEmpty { segments.append(words); words = [] } }
    while i < it.count {
        let c = it[i]
        if let q = quote {
            if c == q { quote = nil }
            else if c == "\\" && q == "\"" && i + 1 < it.count { i += 1; cur.append(it[i]) }
            else { cur.append(c) }
        } else if c == "'" || c == "\"" { quote = c; inWord = true }
        else if c == "\\" && i + 1 < it.count { i += 1; if it[i] != "\n" { cur.append(it[i]); inWord = true } }
        else if c == " " || c == "\t" { endWord() }
        else if ";&|\n(){}`".contains(c) { endSeg() }
        else if c == "$" && i + 1 < it.count && it[i + 1] == "(" { endSeg(); i += 1 }
        else { cur.append(c); inWord = true }
        i += 1
    }
    endSeg()
    it = []
    return segments
}

/// Why a command would put something on the user's screen, or nil if it's fine.
func screenIntrusion(_ command: String, depth: Int = 0) -> String? {
    for var w in shellSegments(command) {
        // Explicit, deliberate escape hatch: `BACKSTAGE_SHOW=1 open …`
        var showOK = false
        while let f = w.first, f.contains("="), !f.hasPrefix("="), f.first!.isLetter || f.first == "_" {
            if f == "BACKSTAGE_SHOW=1" { showOK = true }
            w.removeFirst()
        }
        while let f = w.first, ["sudo", "env", "exec", "nohup", "command", "time", "caffeinate"].contains(f) {
            w.removeFirst()
            while let g = w.first, g.hasPrefix("-") || g.contains("=") { if g == "BACKSTAGE_SHOW=1" { showOK = true }; w.removeFirst() }
        }
        guard let exe = w.first else { continue }
        let name = (exe as NSString).lastPathComponent
        let args = Array(w.dropFirst())
        if showOK { continue }
        if ["bash", "sh", "zsh"].contains(name), let i = args.firstIndex(where: { $0.hasPrefix("-") && $0.hasSuffix("c") }), i + 1 < args.count, depth < 3,
           let r = screenIntrusion(args[i + 1], depth: depth + 1) { return r }
        if name == "open" {
            if args.isEmpty || args.contains(where: { ["-h", "--help"].contains($0) }) { continue }
            return "`open` brings an app, file or URL to the front of the user's screen"
        }
        if exe.contains(".app/Contents/MacOS/") {
            return "running an app bundle's executable directly opens its windows on the user's screen"
        }
        if name == "osascript" {
            let script = args.joined(separator: " ").lowercased()
            if script.contains("activate") || script.contains(" launch") || script.contains("open ") || script.contains("reopen") {
                return "this AppleScript activates or opens an app on the user's screen"
            }
        }
    }
    return nil
}

func hookDenyMessage(_ why: String, _ command: String) -> String {
    """
    backstage: blocked, because \(why). Command: \(command.count > 160 ? String(command.prefix(160)) + "…" : command)
    • Checking your own work (build/test/verify/debug/screenshot/explore)? Run it hidden: `backstage launch <app|bundle-id|path>`, then screenshot/tree/click (see the backstage skill or `backstage help`).
    • Did the user explicitly ask to see it on their screen? Use `backstage show <app|file|url>`, or `backstage show --pid P` to hand over an app you launched hidden.
    """
}

/// `backstage hook pre-tool-use`: read the agent's hook payload on stdin, and exit 2 with a
/// reason on stderr to deny. Exit 2 + stderr means "deny" in Claude Code, Codex and Grok alike.
/// Fails open: unparseable input or other tools are allowed.
func runPreToolUseHook() -> Never {
    if ProcessInfo.processInfo.environment["BACKSTAGE_HOOK"] == "off" { exit(0) }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let command = hookCommand(payload), let why = screenIntrusion(command) else { exit(0) }
    FileHandle.standardError.write(hookDenyMessage(why, command).data(using: .utf8)!)
    exit(2)
}

// MARK: - show (deliberately put something on the user's screen)

func cmdShow(_ args: Args) throws -> [String: Any] {
    if let target = args.pos(0) {
        if args.opt("pid") != nil || args.opt("app") != nil { throw CLIError("give either a target or --pid/--app, not both") }
        var openArgs: [String] = []
        if let u = URL(string: target), let s = u.scheme, s.count > 1, !target.hasPrefix("/") { openArgs = [target] }
        else {
            let path = (target as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                if !isDir.boolValue, FileManager.default.isExecutableFile(atPath: path), !path.hasSuffix(".app") {
                    openArgs = [try wrapExecutable(URL(fileURLWithPath: path)).path]   // bare GUI binary
                } else {
                    openArgs = [URL(fileURLWithPath: path).standardizedFileURL.path]
                }
            } else {
                openArgs = [try resolveApp(target).path]
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = openArgs
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CLIError("open failed for \(target)") }
        logShown("open \(openArgs.joined(separator: " "))")
        return ["ok": true, "shown": openArgs[0]]
    }

    // Hand a managed (hidden) app over to the user: stop managing it, move it, bring it forward.
    let pid = try managedPid(args)
    try handOver(pid: pid)
    return ["ok": true, "pid": pid, "note": "app is now on the user's screen and no longer managed by backstage"]
}

/// Move a managed app onto the user's screen and stop managing it (used by `show` and the menu bar).
/// `wait: false` (the daemon's menu) never blocks the daemon's main thread on a CLI that holds a lock.
/// Callers check ownership (the CLI goes through `managedApp`); this locks the record's owning session.
func handOver(pid: pid_t, wait: Bool = true) throws {
    let lifecycle = try StateLock("lifecycle.lock", nonblocking: !wait, shared: true)
    defer { lifecycle.release() }
    guard let record = AppStore.load().first(where: { $0.pid == pid }) else { throw CLIError("pid \(pid) is not a live managed app") }
    let owner = try Locks.session(record.owner, nonblocking: !wait)
    defer { owner.release() }
    guard AppStore.load().contains(where: { $0.pid == pid && $0.processStart == record.processStart }) else {
        throw CLIError("pid \(pid) is not a live managed app")
    }
    guard let target = userDisplayBounds().first else { throw CLIError("no user display available for handoff") }
    guard let app = NSRunningApplication(processIdentifier: pid) else { throw CLIError("app \(pid) is gone") }
    try AppStore.remove(pid)
    pump(0.2) // the daemon re-reads the app list on change; give it a beat so it stops pulling windows back
    for (i, w) in axApp(pid).windows.enumerated() {
        let size = w.size ?? CGSize(width: 600, height: 400)
        let x = target.midX - size.width / 2 + CGFloat(i * 30), y = max(target.minY + 60, target.midY - size.height / 2 + CGFloat(i * 30))
        w.setPosition(CGPoint(x: x, y: y))
    }
    // Activation: AX first (works regardless of cooperative-activation rules), then AppKit.
    AXUIElementSetAttributeValue(axApp(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if !app.isActive { app.activate() }
    pump(0.3)
    logShown("handed over pid \(pid) (\(app.localizedName ?? "?"))")
}

private func logShown(_ s: String) {
    try? Paths.ensure()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let url = Paths.dir.appendingPathComponent("shown.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// MARK: - install / uninstall into agents

func homeDir() -> URL {
    if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
    return FileManager.default.homeDirectoryForCurrentUser
}

enum Agent: String, CaseIterable {
    case claude, codex, grok
    var root: URL { homeDir().appendingPathComponent("." + rawValue) }
    var skillDir: URL { root.appendingPathComponent("skills/backstage") }
    var hookMatcher: String {
        switch self {
        case .claude: return "Bash"
        case .codex: return "Bash|exec_command|shell|local_shell"
        case .grok: return "Bash|run_terminal_command|run_terminal_cmd"
        }
    }
    var hookFile: URL {
        switch self {
        case .claude: return root.appendingPathComponent("settings.json")
        case .codex: return root.appendingPathComponent("hooks.json")
        case .grok: return root.appendingPathComponent("config.toml")
        }
    }
}

/// Stable path to this binary for hook configs: the PATH entry (e.g. a Homebrew symlink) when we
/// were invoked through one, so rebuilding or relocating the build dir doesn't break hooks.
func selfCommandPath() -> String {
    let a0 = CommandLine.arguments[0]
    if a0.contains("/") { return URL(fileURLWithPath: a0).standardizedFileURL.path }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let p = "\(dir)/\(a0)"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return Bundle.main.executablePath ?? a0
}

private let hookSuffix = " hook pre-tool-use"
private let ownershipComment = " # backstage-managed-hook"

private func ownedHook(_ hook: [String: Any]) -> Bool {
    guard hook["type"] as? String == "command", let cmd = hook["command"] as? String else { return false }
    if cmd.hasSuffix(hookSuffix + ownershipComment) { return true }
    // The original installer emitted an absolute, unquoted path with this exact suffix.
    guard cmd.hasSuffix(hookSuffix) else { return false }
    let path = String(cmd.dropLast(hookSuffix.count))
    return path.hasPrefix("/") && path.hasSuffix("/backstage") &&
        path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
        path.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>`$()#\n\r")) == nil
}
let tomlBegin = "# >>> backstage hook (managed by `backstage install`) >>>"
let tomlEnd = "# <<< backstage hook <<<"

private func backup(_ url: URL) throws {
    let bak = url.appendingPathExtension("backstage-bak")
    if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: bak.path) {
        try FileManager.default.copyItem(at: url, to: bak)
    }
}

/// Add/remove our PreToolUse entry in a Claude-style JSON hooks file, leaving everything else intact.
private func editJSONHooks(_ url: URL, matcher: String, command: String?) throws -> String {
    var root: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
        let d = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw CLIError("\(url.path) is not a JSON object; not touching it") }
        root = obj
    }
    guard var hooks = (root["hooks"] ?? [String: Any]()) as? [String: Any],
          var pre = (hooks["PreToolUse"] ?? [[String: Any]]()) as? [[String: Any]] else {
        throw CLIError("invalid hooks or PreToolUse in \(url.path)")
    }
    var removed = false
    pre = try pre.compactMap { group in
        guard let entries = group["hooks"] as? [[String: Any]] else {
            throw CLIError("invalid PreToolUse group in \(url.path)")
        }
        let kept = entries.filter { !ownedHook($0) }
        guard kept.count != entries.count else { return group }
        removed = true
        guard !kept.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = kept
        return updated
    }
    if let command {
        pre.append(["matcher": matcher, "hooks": [["type": "command", "command": command, "timeout": 5]]])
    } else if !removed {
        return "no backstage hook present"
    }
    hooks["PreToolUse"] = pre.isEmpty ? nil : pre
    root["hooks"] = hooks.isEmpty ? nil : hooks
    try backup(url)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    try out.write(to: url, options: .atomic)
    return command == nil ? "removed hook" : (removed ? "updated hook" : "added hook")
}

/// Same for Grok's config.toml, using a marked block so it can be removed cleanly.
private func editTOMLHooks(_ url: URL, matcher: String, command: String?) throws -> String {
    var text = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    var removed = false
    let lines = text.components(separatedBy: "\n")
    let starts = lines.indices.filter { lines[$0] == tomlBegin }
    let ends = lines.indices.filter { lines[$0] == tomlEnd }
    if !starts.isEmpty || !ends.isEmpty {
        guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else {
            throw CLIError("incomplete or duplicate backstage hook markers in \(url.path)")
        }
        var kept = lines
        kept.removeSubrange(starts[0]...ends[0])
        text = kept.joined(separator: "\n")
        removed = true
    }
    if let command {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += """
        \(tomlBegin)
        [[hooks.PreToolUse]]
        matcher = \(q(matcher))
          [[hooks.PreToolUse.hooks]]
          type = "command"
          command = \(q(command))
          timeout = 5
        \(tomlEnd)

        """
    } else if !removed {
        return "no backstage hook present"
    }
    try backup(url)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return command == nil ? "removed hook" : (removed ? "updated hook" : "added hook")
}

func selectedAgents(_ args: Args) -> [Agent] {
    let picked = Agent.allCases.filter { args.has($0.rawValue) }
    if !picked.isEmpty { return picked }
    // Default: every agent that's set up on this machine.
    return Agent.allCases.filter { FileManager.default.fileExists(atPath: $0.root.path) }
}

func cmdInstall(_ args: Args) throws -> [String: Any] {
    let agents = selectedAgents(args)
    guard !agents.isEmpty else { throw CLIError("no agent config dirs found (~/.claude, ~/.codex, ~/.grok); pass --claude/--codex/--grok") }
    let path = selfCommandPath().replacingOccurrences(of: "'", with: "'\\''")
    let command = "'\(path)'" + hookSuffix + ownershipComment
    var report: [String: Any] = [:]
    for a in agents {
        var r: [String: Any] = [:]
        let skill = a.skillDir.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: skill.path),
           try String(contentsOf: skill, encoding: .utf8) != skillMarkdown {
            throw CLIError("found a different skill at \(skill.path); move it before installing")
        }
        if args.has("hooks") {
            r["hook"] = a == .grok ? try editTOMLHooks(a.hookFile, matcher: a.hookMatcher, command: command)
                                   : try editJSONHooks(a.hookFile, matcher: a.hookMatcher, command: command)
            r["hookFile"] = a.hookFile.path
        }
        try FileManager.default.createDirectory(at: a.skillDir, withIntermediateDirectories: true)
        try skillMarkdown.write(to: skill, atomically: true, encoding: .utf8)
        r["skill"] = skill.path
        report[a.rawValue] = r
    }
    var out: [String: Any] = ["ok": true, "installed": report]
    if args.has("hooks") {
        out["hookCommand"] = command
        out["note"] = "Restart running agent sessions to pick up hooks. Grok only runs hooks it trusts: run /hooks-list in Grok to check."
    } else {
        out["note"] = "Skills only. Add --hooks to also block agents from opening apps on your screen directly."
    }
    return out
}

func cmdUninstall(_ args: Args) throws -> [String: Any] {
    var report: [String: Any] = [:]
    for a in selectedAgents(args) {
        var r: [String: Any] = [:]
        let skill = a.skillDir.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: a.hookFile.path) {
            r["hook"] = a == .grok ? try editTOMLHooks(a.hookFile, matcher: a.hookMatcher, command: nil)
                                   : try editJSONHooks(a.hookFile, matcher: a.hookMatcher, command: nil)
        }
        if FileManager.default.fileExists(atPath: skill.path) {
            if try String(contentsOf: skill, encoding: .utf8) == skillMarkdown {
                try FileManager.default.removeItem(at: skill)
                // rmdir removes only an empty directory, even if another writer adds a file.
                _ = rmdir(a.skillDir.path)
                r["skill"] = "removed"
            } else {
                r["skill"] = "preserved different skill"
            }
        }
        report[a.rawValue] = r
    }
    return ["ok": true, "uninstalled": report]
}
