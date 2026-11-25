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
    let it = Array(s)
    var i = 0
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

/// The agent runs inside a desktop app that offers computer-use tools: the Claude desktop app
/// (its Code and local agent sessions set CLAUDE_CODE_ENTRYPOINT) or the Codex desktop app (sets
/// CODEX_INTERNAL_ORIGINATOR_OVERRIDE for its codex processes). Only reorders the deny message's
/// advice: terminal Codex sessions can have computer use too, so this is no reason to allow anything.
func desktopComputerUseHost(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    if let e = env["CLAUDE_CODE_ENTRYPOINT"], ["claude-desktop", "claude-desktop-3p", "local-agent", "local_agent"].contains(e) { return true }
    return !(env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] ?? "").isEmpty
}

func hookDenyMessage(_ why: String, _ command: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let own = "• Checking your own work (build/test/verify/debug/screenshot/explore)? Run it hidden: `backstage launch <app|bundle-id|path>` (`--display new` for a hidden display of your own), then screenshot/tree/click (see the backstage skill or `backstage help`)."
    let user = "• Did the user explicitly ask to see it on their screen? Use `backstage show <app|file|url>`, or `backstage show --pid P` to hand over an app you launched hidden."
    let computerUse = "• Going to drive it with computer-use tools that work on the user's screen (screenshots of their display, the real mouse and keyboard)? "
        + "They can't see backstage's hidden display: put the app on the user's screen with `backstage show <app>` (`backstage show --pid P` if you launched it hidden), "
        + "or use your computer-use tool's own open-application action."
    let advice = desktopComputerUseHost(env) ? [computerUse, own, user] : [own, user, computerUse]
    return "backstage: blocked, because \(why). Command: \(command.count > 160 ? String(command.prefix(160)) + "…" : command)\n"
        + advice.joined(separator: "\n")
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
        // The app that will open the target, to keep LaunchServices from handing it to a
        // hidden instance that backstage manages (possibly for another session).
        var handler: URL?
        var isApp = false
        if let u = URL(string: target), let s = u.scheme, s.count > 1, !target.hasPrefix("/") {
            openArgs = [target]
            handler = NSWorkspace.shared.urlForApplication(toOpen: u)
        } else {
            let path = (target as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                if !isDir.boolValue, FileManager.default.isExecutableFile(atPath: path), !path.hasSuffix(".app") {
                    // Bare GUI binary: its own wrapper, never the one `launch` runs hidden.
                    openArgs = [try wrapExecutable(URL(fileURLWithPath: path), shown: true).path]
                } else {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    openArgs = [url.path]
                    isApp = Bundle(url: url)?.bundleIdentifier != nil && url.pathExtension == "app"
                    handler = isApp ? url : NSWorkspace.shared.urlForApplication(toOpen: url)
                }
            } else {
                let url = try resolveApp(target)
                openArgs = [url.path]
                isApp = true
                handler = url
            }
        }
        if let handler, managedInstanceRunning(of: handler) {
            // -n: a new instance for the user, rather than activating the hidden one.
            openArgs = isApp ? ["-n"] + openArgs : ["-n", "-a", handler.path] + openArgs
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = openArgs
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CLIError("open failed for \(target)") }
        logShown("open \(openArgs.joined(separator: " "))")
        return ["ok": true, "shown": openArgs.last!]
    }

    // Hand a managed (hidden) app over to the user: stop managing it, move it, bring it forward.
    let app = try managedApp(args)
    let (unmuted, dock) = try handOver(app)
    if app.audioMode == .inaudible {
        // The app silenced itself from inside at launch; removing the tap can't undo that.
        return ["ok": true, "pid": app.pid, "audio": "inaudible", "dock": dock,
                "note": "app is now on the user's screen and no longer managed by backstage; it was launched inaudible, so the user "
                    + "still can't hear it (relaunch it with `show <app>`, or `launch --audio` then `show --pid`, for sound)"]
    }
    return ["ok": true, "pid": app.pid, "audio": unmuted ? "unmuted" : "unknown", "dock": dock,
            "note": "app is now on the user's screen and no longer managed by backstage; "
                + (unmuted ? "its audio is no longer muted, so the user hears it" : "backstage couldn't confirm its audio tap was removed")]
}

/// A live managed (hidden) instance of this app exists, in any session.
private func managedInstanceRunning(of app: URL) -> Bool {
    let resolved = app.resolvingSymlinksInPath().standardizedFileURL
    let bundleID = Bundle(url: app)?.bundleIdentifier
    return AppStore.load().contains {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL == resolved
            || (bundleID != nil && $0.bundleID == bundleID)
    }
}

/// Move a managed app onto the user's screen and stop managing it (used by `show` and the menu bar).
/// `wait: false` (the daemon's menu) never blocks the daemon's main thread on a CLI that holds a lock.
/// Callers check ownership (the CLI goes through `managedApp`) and pass the record they checked;
/// this locks its owning session and hands over only that same process (PID, start time, owner),
/// so a reused PID can't hand over another session's app.
/// Returns `unmuted` true once the daemon has removed the app's audio tap (it's audible again);
/// `wait: false` doesn't wait for that. `dock` says whether the app got back the Dock tile and
/// ⌘-Tab entry `launch` hid (see `restoreDock`).
@discardableResult
func handOver(_ record: ManagedApp, wait: Bool = true) throws -> (unmuted: Bool, dock: String) {
    let pid = record.pid
    let lifecycle = try StateLock("lifecycle.lock", nonblocking: !wait, shared: true)
    defer { lifecycle.release() }
    let owner = try Locks.session(record.owner, nonblocking: !wait)
    defer { owner.release() }
    let input = try Locks.app(record, nonblocking: !wait)
    defer { input.release() }
    try rejectIncompatibleDaemon()
    func same(_ a: ManagedApp) -> Bool {
        a.pid == pid && a.processStart == record.processStart && Session.sameID(a.owner, record.owner)
    }
    guard AppStore.load().contains(where: same) else { throw CLIError("pid \(pid) is not a live managed app") }
    guard let target = userDisplayBounds().first else { throw CLIError("no user display available for handoff") }
    guard let birth = record.liveProcessBirth,
          let app = NSRunningApplication(processIdentifier: pid) else { throw CLIError("app \(pid) is gone") }
    func checkProcess() throws {
        guard processBirth(pid) == birth else { throw CLIError("app \(pid) exited during handoff") }
    }
    try checkProcess()
    try AppStore.update { $0.removeAll(where: same) }
    pump(0.2) // the daemon re-reads the app list on change; give it a beat so it stops pulling windows back
    // The daemon sees the handover and destroys the app's tap: from then on the user hears it.
    let status = record.processStart.map { AudioFiles.status(pid, $0) }
    let unmuted = !wait || status == nil
        || waitFor(timeout: 2, { FileManager.default.fileExists(atPath: status!.path) ? nil : true }) != nil
    try checkProcess()
    for (i, w) in axApp(pid).windows.enumerated() {
        let size = w.size ?? CGSize(width: 600, height: 400)
        let x = target.midX - size.width / 2 + CGFloat(i * 30), y = max(target.minY + 60, target.midY - size.height / 2 + CGFloat(i * 30))
        try checkProcess()
        w.setPosition(CGPoint(x: x, y: y))
    }
    try checkProcess()
    // A regular app again (Dock tile, ⌘-Tab) before it's activated for the user.
    let dock = restoreDock(pid)
    try checkProcess()
    // Activation: AX first (works regardless of cooperative-activation rules), then AppKit.
    AXUIElementSetAttributeValue(axApp(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if !app.isActive { app.activate() }
    pump(0.3)
    logShown("handed over pid \(pid) (\(app.localizedName ?? "?")), dock: \(dock)")
    return (unmuted, dock)
}

private func logShown(_ s: String) {
    try? Paths.ensure()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let url = Paths.dir.appendingPathComponent("shown.log")
    appendLogLine(line, to: url)
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
        if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p).standardizedFileURL.path }
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
private let tomlBeginAfterMissingNewline = tomlBegin + " (added separator)"

/// Atomic replacement must target the file behind a user-managed symlink.
func configurationTarget(_ url: URL) throws -> URL {
    var metadata = stat()
    if lstat(url.path, &metadata) != 0 {
        if errno == ENOENT { return url }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let target = url.resolvingSymlinksInPath()
    guard stat(target.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
        throw CLIError("expected a regular configuration file at \(url.path)")
    }
    return target
}

func configurationData(_ url: URL) throws -> Data? {
    do { return try Data(contentsOf: url) }
    catch CocoaError.fileReadNoSuchFile { return nil }
}

private func backup(_ url: URL) throws {
    let bak = url.appendingPathExtension("backstage-bak")
    do { try FileManager.default.copyItem(at: url, to: bak) }
    catch CocoaError.fileWriteFileExists { }
}

/// Install and uninstall for one agent share the directory lock, regardless of BACKSTAGE_HOME.
private func withAgentLock<T>(_ agent: Agent, create: Bool, _ body: () throws -> T) throws -> T? {
    if create { try FileManager.default.createDirectory(at: agent.root, withIntermediateDirectories: true) }
    let fd = open(agent.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if fd < 0 {
        if !create && errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
        if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    return try body()
}

/// Add/remove our PreToolUse entry in a Claude-style JSON hooks file, leaving everything else intact.
private func editJSONHooks(_ url: URL, matcher: String, command: String?) throws -> String {
    let target = try configurationTarget(url)
    var root: [String: Any] = [:]
    let source = try configurationData(target)
    if let d = source {
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw CLIError("\(url.path) is not a JSON object; not touching it") }
        root = obj
    }
    guard var hooks = (root["hooks"] ?? [String: Any]()) as? [String: Any],
          var pre = (hooks["PreToolUse"] ?? [[String: Any]]()) as? [[String: Any]] else {
        throw CLIError("invalid hooks or PreToolUse in \(url.path)")
    }
    let previous = pre
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
        if NSArray(array: pre).isEqual(to: previous) { return "hook already installed" }
    } else if !removed {
        return "no backstage hook present"
    }
    hooks["PreToolUse"] = pre.isEmpty ? nil : pre
    root["hooks"] = hooks.isEmpty ? nil : hooks
    if source != nil { try backup(target) }
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    try out.write(to: target, options: .atomic)
    return command == nil ? "removed hook" : (removed ? "updated hook" : "added hook")
}

/// Same for Grok's config.toml, using a marked block so it can be removed cleanly.
private func editTOMLHooks(_ url: URL, matcher: String, command: String?) throws -> String {
    let target = try configurationTarget(url)
    let source = try configurationData(target)
    guard var text = String(data: source ?? Data(), encoding: .utf8) else {
        throw CLIError("invalid UTF-8 in \(url.path)")
    }
    var removed = false
    let lines = text.components(separatedBy: "\n")
    let markers = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    let starts = markers.indices.filter { markers[$0] == tomlBegin || markers[$0] == tomlBeginAfterMissingNewline }
    let ends = markers.indices.filter { markers[$0] == tomlEnd }
    if !starts.isEmpty || !ends.isEmpty {
        guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else {
            throw CLIError("incomplete or duplicate backstage hook markers in \(url.path)")
        }
        var kept = lines
        kept.removeSubrange(starts[0]...ends[0])
        if starts[0] > 0, kept.count == starts[0] || (kept.count == starts[0] + 1 && kept.last == "") {
            // The block is at EOF. Restore the original ending, even if an editor removed
            // the newline after the closing marker.
            if markers[starts[0]] == tomlBeginAfterMissingNewline {
                if kept.count > starts[0] { kept.removeLast() }
                if let last = kept.indices.last, kept[last].hasSuffix("\r") { kept[last].removeLast() }
            } else if kept.count == starts[0] {
                kept.append("")
            }
        }
        text = kept.joined(separator: "\n")
        removed = true
    }
    if let command {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func q(_ s: String) throws -> String {
            String(decoding: try encoder.encode(s), as: UTF8.self).replacingOccurrences(of: "\u{7f}", with: "\\u007f")
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let needsSeparator = !text.isEmpty && text.utf8.last != 0x0a
        if needsSeparator { text += newline }
        let block = """
        \(needsSeparator ? tomlBeginAfterMissingNewline : tomlBegin)
        [[hooks.PreToolUse]]
        matcher = \(try q(matcher))
          [[hooks.PreToolUse.hooks]]
          type = "command"
          command = \(try q(command))
          timeout = 5
        \(tomlEnd)

        """
        text += block.replacingOccurrences(of: "\n", with: newline)
    } else if !removed {
        return "no backstage hook present"
    }
    let output = Data(text.utf8)
    if output == source { return "hook already installed" }
    if source != nil { try backup(target) }
    try output.write(to: target, options: .atomic)
    return command == nil ? "removed hook" : (removed ? "updated hook" : "added hook")
}

func selectedAgents(_ args: Args) -> [Agent] {
    let picked = Agent.allCases.filter { args.has($0.rawValue) }
    if !picked.isEmpty { return picked }
    // Default: every agent that's set up on this machine.
    return Agent.allCases.filter { FileManager.default.fileExists(atPath: $0.root.path) }
}

/// Any version of backstage's own skill (its frontmatter names it), as opposed to a user's
/// unrelated skill that happens to live in the same folder.
func isBackstageSkill(_ text: String) -> Bool {
    let lines = text.split(maxSplits: 2, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    return lines.count > 1 && lines[0] == "---" && lines[1].trimmingCharacters(in: .whitespaces) == "name: backstage"
}

func cmdInstall(_ args: Args) throws -> [String: Any] {
    let agents = selectedAgents(args)
    guard !agents.isEmpty else { throw CLIError("no agent config dirs found (~/.claude, ~/.codex, ~/.grok); pass --claude/--codex/--grok") }
    let path = selfCommandPath().replacingOccurrences(of: "'", with: "'\\''")
    let command = "'\(path)'" + hookSuffix + ownershipComment
    var report: [String: Any] = [:]
    for a in agents {
        report[a.rawValue] = try withAgentLock(a, create: true) {
            var r: [String: Any] = [:]
            let skill = a.skillDir.appendingPathComponent("SKILL.md")
            let target = try configurationTarget(skill)
            let previous = try configurationData(target)
            let output = Data(skillMarkdown.utf8)
            if let previous {
                guard let existing = String(data: previous, encoding: .utf8), isBackstageSkill(existing) else {
                    throw CLIError("found a different skill at \(skill.path); move it before installing")
                }
                var metadata = stat()
                if previous != output, lstat(skill.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFLNK {
                    throw CLIError("found a linked skill at \(skill.path); update its target before installing")
                }
            }
            if args.has("hooks") {
                r["hook"] = a == .grok ? try editTOMLHooks(a.hookFile, matcher: a.hookMatcher, command: command)
                                       : try editJSONHooks(a.hookFile, matcher: a.hookMatcher, command: command)
                r["hookFile"] = a.hookFile.path
            }
            if previous != output {
                if previous != nil {
                    // Keep the previous copy without replacing any existing backup.
                    let bak = skill.appendingPathExtension("backstage-bak")
                    do {
                        try FileManager.default.copyItem(at: target, to: bak)
                        r["previousSkill"] = bak.path
                    } catch CocoaError.fileWriteFileExists {
                        let next = bak.appendingPathExtension(UUID().uuidString)
                        try FileManager.default.copyItem(at: target, to: next)
                        r["previousSkill"] = next.path
                    }
                }
                try FileManager.default.createDirectory(at: a.skillDir, withIntermediateDirectories: true)
                try output.write(to: target, options: .atomic)
            }
            r["skill"] = skill.path
            return r
        }
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
        report[a.rawValue] = try withAgentLock(a, create: false) {
            var r: [String: Any] = [:]
            let skill = a.skillDir.appendingPathComponent("SKILL.md")
            r["hook"] = a == .grok ? try editTOMLHooks(a.hookFile, matcher: a.hookMatcher, command: nil)
                                   : try editJSONHooks(a.hookFile, matcher: a.hookMatcher, command: nil)
            var metadata = stat()
            if lstat(skill.path, &metadata) == 0 {
                // A custom link may expose a shared skill. It remains under the user's control.
                if metadata.st_mode & S_IFMT == S_IFREG,
                   let existing = try? String(contentsOf: skill, encoding: .utf8), isBackstageSkill(existing) {
                    try FileManager.default.removeItem(at: skill)
                    // rmdir removes only an empty directory, even if another writer adds a file.
                    _ = rmdir(a.skillDir.path)
                    r["skill"] = "removed"
                } else {
                    r["skill"] = "preserved different skill"
                }
            }
            return r
        } ?? [:]
    }
    return ["ok": true, "uninstalled": report]
}
