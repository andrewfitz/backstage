import Foundation
import AppKit

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func emit(_ obj: Any) {
    let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: opts), let s = String(data: d, encoding: .utf8) {
        print(s)
    } else {
        print(obj)
    }
}

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Spin the run loop (needed for AppKit/KVO bookkeeping and async work) for `seconds`.
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

/// Poll `cond` until it returns non-nil or the timeout elapses.
func waitFor<T>(timeout: Double, interval: Double = 0.05, _ cond: () throws -> T?) rethrows -> T? {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        if let v = try cond() { return v }
        let remaining = end - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { break }
        pump(min(interval, remaining))
    } while true
    return nil
}

/// Run an async closure synchronously from the CLI's main thread.
func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let pending = DispatchGroup()
    var result: Result<T, Error>?
    pending.enter()
    Task.detached {
        defer { pending.leave() }
        do { result = .success(try await body()) }
        catch { result = .failure(error) }
    }
    while pending.wait(timeout: .now()) != .success { pump(0.01) }
    return try result!.get()
}

func r(_ v: CGFloat) -> Int { Int(v.rounded()) }
func rectDict(_ r0: CGRect) -> [String: Int] { ["x": r(r0.origin.x), "y": r(r0.origin.y), "w": r(r0.width), "h": r(r0.height)] }

/// Simple argument parser: positional args + `--flag value` / `--switch`.
struct Args {
    var positional: [String] = []
    private var options: [String: [String]] = [:]
    private var switches: Set<String> = []
    var passthrough: [String] = []

    init(_ raw: [String], command: String) throws {
        let flags: Set<String> = ["help", "json", "force", "double", "right", "raw", "gone", "full", "claude", "codex", "grok", "hooks"]
        let values: Set<String> = ["pid", "app", "env", "timeout", "lines", "scale", "o", "out",
                                   "window", "depth", "role", "text", "ref", "steps", "dx", "dy"]
        var i = 0
        while i < raw.count {
            let token = raw[i]
            i += 1
            if token == "--" {
                let rest = Array(raw.dropFirst(i))
                if ["launch", "open"].contains(command) { passthrough = rest }
                else { positional += rest }
                break
            }
            if token == "-h" { switches.insert("help"); continue }
            guard token.hasPrefix("--") || token == "-o" else {
                positional.append(token)
                continue
            }
            let option = token == "-o" ? "o" : String(token.dropFirst(2))
            let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            if flags.contains(name) {
                guard parts.count == 1 else { throw CLIError("--\(name) takes no value") }
                switches.insert(name)
                continue
            }
            guard values.contains(name) else { throw CLIError("unknown option --\(name)") }
            let value: String
            if parts.count == 2 { value = String(parts[1]) }
            else {
                guard i < raw.count, !raw[i].hasPrefix("--") else { throw CLIError("--\(name) needs a value") }
                value = raw[i]
                i += 1
            }
            guard name == "env" || options[name] == nil else { throw CLIError("repeated option --\(name)") }
            options[name, default: []].append(value)
        }
        if has("help") { return }
        let target = ["pid", "app"]
        let allowed: [String]
        let arity: ClosedRange<Int>
        switch command {
        case "launch", "open":
            allowed = ["env", "timeout"]; arity = 1...1
            for entry in multi("env") {
                guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else {
                    throw CLIError("--env needs NAME=value")
                }
            }
        case "quit", "kill": allowed = target + ["force"]; arity = 0...0
        case "logs": allowed = target + ["lines"]; arity = 0...0
        case "windows": allowed = target; arity = 0...0
        case "screenshot", "shot":
            allowed = target + ["window", "o", "out", "scale", "full"]; arity = 0...0
            if has("full"), (target + ["window"]).contains(where: { opt($0) != nil }) {
                throw CLIError("--full captures the entire agent display and takes no app or window selector")
            }
            if opt("o") != nil && opt("out") != nil { throw CLIError("supply one output path") }
        case "tree": allowed = target + ["window", "depth", "json"]; arity = 0...0
        case "wait", "find":
            allowed = target + ["window", "role", "text"] + (command == "wait" ? ["timeout", "gone"] : [])
            arity = 0...(opt("text") == nil ? 1 : 0)
        case "press", "focus", "menu": allowed = target; arity = 1...1
        case "set", "action": allowed = target; arity = 2...2
        case "type": allowed = target + ["ref"]; arity = 1...1
        case "key": allowed = target + ["ref"]; arity = 1...Int.max
        case "click":
            allowed = target + ["ref", "right", "double", "raw", "scale"]
            arity = opt("ref") == nil ? 2...2 : 0...0
        case "hover": allowed = target + ["scale"]; arity = 2...2
        case "show": allowed = target; arity = 0...1
        case "install": allowed = ["claude", "codex", "grok", "hooks"]; arity = 0...0
        case "uninstall": allowed = ["claude", "codex", "grok"]; arity = 0...0
        case "hook": allowed = []; arity = 1...1
        case "skill": allowed = []; arity = 0...0
        case "scroll": allowed = target + ["scale", "dx", "dy"]; arity = 2...2
        case "drag": allowed = target + ["scale", "steps"]; arity = 4...4
        default: allowed = []; arity = 0...0
        }
        if let unexpected = switches.union(options.keys).subtracting(allowed).sorted().first {
            throw CLIError("--\(unexpected) is not an option for \(command)")
        }
        guard arity.contains(positional.count) else { throw CLIError("wrong number of arguments for \(command). Run backstage help.") }
        guard opt("pid") == nil || opt("app") == nil else { throw CLIError("choose one of --pid and --app") }
        if let pid = opt("pid"), (Int32(pid) ?? 0) <= 0 { throw CLIError("--pid needs a positive process ID") }
        if opt("app") == "" { throw CLIError("--app needs a name or bundle identifier") }
        for name in ["lines", "depth", "steps"] where opt(name) != nil {
            guard let n = int(name), n >= (name == "steps" ? 1 : 0) else { throw CLIError("invalid --\(name)") }
        }
        for name in ["dx", "dy"] where opt(name) != nil && Int32(opt(name)!) == nil {
            throw CLIError("--\(name) must fit in a signed 32-bit integer")
        }
        for name in ["timeout", "scale"] where opt(name) != nil {
            guard let n = double(name), n.isFinite, n >= 0, name != "scale" || n > 0 else {
                throw CLIError("invalid --\(name)")
            }
        }
    }
    func has(_ s: String) -> Bool { switches.contains(s) }
    func opt(_ k: String) -> String? { options[k]?.last }
    func multi(_ k: String) -> [String] { options[k] ?? [] }
    func double(_ k: String) -> Double? { opt(k).flatMap(Double.init) }
    func int(_ k: String) -> Int? { opt(k).flatMap(Int.init) }
    func pos(_ i: Int) -> String? { positional.indices.contains(i) ? positional[i] : nil }
}
