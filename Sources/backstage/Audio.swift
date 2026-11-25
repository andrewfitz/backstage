import Foundation
import Accelerate
import CBackstageAudio

// Audio: the daemon mutes every managed app with a private process tap (AudioTaps.swift) and
// publishes what it measures as files; these CLI commands read them. See docs/AUDIO_PLAN.md.

/// `playing` means the (compensated) peak reached this within the last 0.3 s; `sounds` are split
/// at it. A tap's silence is exact digital zero, so the floor only has to sit above the dither
/// and denormal noise some apps emit while "silent". It also holds a -60 dBFS stereo sound on
/// a multichannel device even uncompensated (-74 dBFS on 10 channels, -80 on 20).
let audioFloorDb = -80.0
let audioSoundGap = 0.3
/// The published ring holds the last this-many seconds of an app's tap (`audio record`'s maximum).
let audioRingSeconds = 15.0

enum AudioFiles {
    static var dir: URL { Paths.dir.appendingPathComponent("audio") }
    static var health: URL { dir.appendingPathComponent("daemon.json") }
    static func status(_ pid: pid_t, _ birth: UInt64) -> URL { dir.appendingPathComponent("\(pid)-\(birth).json") }
    static func ring(_ pid: pid_t, _ birth: UInt64) -> URL { dir.appendingPathComponent("\(pid)-\(birth).pcm") }
    static func selfTestRequest(_ id: String) -> URL { dir.appendingPathComponent("selftest-\(id).request") }
    static func selfTestResult(_ id: String) -> URL { dir.appendingPathComponent("selftest-\(id).json") }
}

struct AudioHost: Codable { var pid: Int32; var name: String; var path: String? }

/// audio/daemon.json: the tap manager's health, written by the daemon.
struct AudioHealth: Codable {
    var muting: String              // "ok" | "unavailable"
    var reason: String?
    var capture: String             // "granted" | "not granted"
    var captureSource: String       // "preflight" | "self-test" | "test override"
    var preflight: Int32?
    var host: AudioHost?
    var floorDb: Double
    var updated: Double
}

struct AudioSelfTestResult: Codable {
    var id: String
    var state: String               // "running" | "prompting" | "done"
    var captured: Bool? = nil
    var levelDb: Double? = nil
    var expectedDb: Double = -60
    var hz: Double = 18500
    var device: String? = nil
    var outputOnly: Bool? = nil
    var error: String? = nil
    var ioSetupMs: Double? = nil
    var permission: String? = nil   // "granted" | "not granted"
}

struct AudioSound: Codable {
    var start: Double
    var seconds: Double
    var peakDb: Double
    var rmsDb: Double
    var ongoing: Bool
}

/// audio/<pid>-<birth>.json: one app's tap, rewritten by the daemon on each change and while
/// there's output.
struct AudioAppStatus: Codable {
    var pid: Int32
    var birth: UInt64
    var name: String
    var session: String?
    var tap: String                 // "muted" | "armed" | "failed"
    var reason: String?
    var processes: [Int32]
    var ioRunning: Bool
    var playing: Bool
    var peakDb: Double?
    var rmsDb: Double?
    var sampleRate: Double?
    var channels: Int?
    var outputChannels: Int?
    var levelGainDb: Double?
    var floorDb: Double
    var time: Double
    var sounds: [AudioSound]
    var sightToMuteMs: [Double]?
    var ring: String?
    var launch: String? = nil         // BACKSTAGE_LAUNCH_ID, when the tap was made before registration
    var metered: Bool? = nil          // measured (launch --audio); nil from daemons that measure every app
}

/// Published audio files are private to the user, like the logs (mode 0600).
func writePrivateJSON<T: Encodable>(_ url: URL, _ value: T) throws {
    try writeJSON(url, value)
    chmod(url.path, 0o600)
}

func audioSupported() -> Bool {
    if #available(macOS 14.2, *) { return true }
    return false
}

func readAudioHealth() -> AudioHealth? { readJSON(AudioFiles.health, AudioHealth.self) }

private func hostDescription(_ h: AudioHealth?) -> String {
    guard let host = h?.host else { return "the app that started the backstage daemon (your terminal or agent host)" }
    return "\(host.name)\(host.path.map { " (\($0))" } ?? ""), the app that started the backstage daemon"
}

func audioGrantHelp(_ h: AudioHealth?) -> String {
    "System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only: enable "
        + "\(h?.host?.name ?? "your terminal or agent host"), then run `backstage doctor`"
}

/// `launch` refuses unless the daemon can mute the app (user decision: muting is unconditional).
func requireAudioMuting(_ info: DaemonInfo) throws {
    guard audioSupported() else { throw CLIError("audio muting needs macOS 14.2 or later, so backstage can't launch apps on this Mac") }
    guard let ok = info.audio else {
        throw CLIError("the running backstage daemon (pid \(info.pid)) is from an older build that can't mute apps' audio; "
            + "run `backstage stop --all` (quits every managed app) to replace it, then retry")
    }
    guard ok else {
        throw CLIError("backstage can't mute this launch's audio, so it won't launch it: \(info.audioReason ?? "the daemon's tap manager isn't healthy"). "
            + "See \(Paths.log.path); `backstage stop --all` restarts the daemon")
    }
}

/// `audio` and `wait --sound` need the daemon's host to have System Audio Recording.
@discardableResult
func requireAudioCapture() throws -> AudioHealth {
    guard audioSupported() else { throw CLIError("audio needs macOS 14.2 or later") }
    let d = try requireDaemon()
    guard d.audio == true else {
        throw CLIError(d.audio == nil ? "the running backstage daemon is from an older build without audio; run `backstage stop --all`, then launch again"
                                      : "the daemon's audio taps aren't available: \(d.audioReason ?? "unknown error")")
    }
    guard let h = readAudioHealth() else { throw CLIError("the daemon hasn't published its audio state yet; retry") }
    guard h.capture == "granted" else {
        throw CLIError("can't read audio levels: System Audio Recording isn't granted to \(hostDescription(h)). "
            + "Apps are still muted; only measuring needs it. \(audioGrantHelp(h))")
    }
    return h
}

func readAudioStatus(_ pid: pid_t, _ birth: UInt64?) -> AudioAppStatus? {
    guard let birth else { return nil }
    return readJSON(AudioFiles.status(pid, birth), AudioAppStatus.self)
}

/// Why the daemon quit this app over its audio, if it did.
func audioFailure(_ pid: pid_t, _ birth: UInt64?) -> String? {
    guard let s = readAudioStatus(pid, birth), s.tap == "failed" else { return nil }
    return "backstage quit the app because its audio couldn't be muted: \(s.reason ?? "tap failed")"
}

/// A tap failure for a launch that hasn't registered its app yet (the daemon quit it on sight).
func audioFailure(launch id: String) -> String? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: AudioFiles.dir.path) else { return nil }
    for n in names where n.hasSuffix(".json") && n.first?.isNumber == true {
        if let s = readJSON(AudioFiles.dir.appendingPathComponent(n), AudioAppStatus.self), s.launch == id, s.tap == "failed" {
            return "backstage quit the app because its audio couldn't be muted: \(s.reason ?? "tap failed")"
        }
    }
    return nil
}

private func rounded(_ x: Double, _ places: Double = 10) -> Double { (x * places).rounded() / places }

private func soundDict(_ s: AudioSound) -> [String: Any] {
    ["start": rounded(s.start, 1000), "seconds": rounded(s.seconds, 1000), "peakDb": rounded(s.peakDb), "rmsDb": rounded(s.rmsDb), "ongoing": s.ongoing]
}

/// The status of a live managed app, waiting briefly for the daemon to publish it.
private func liveStatus(_ app: ManagedApp) -> AudioAppStatus? {
    let birth = app.processStart ?? app.liveProcessBirth
    return waitFor(timeout: 1, interval: 0.05) { readAudioStatus(app.pid, birth) }
}

/// The session's app for `audio`/`audio record`, its published status, and the daemon's audio health.
private func audioTarget(_ args: Args) throws -> (ManagedApp, AudioAppStatus, AudioHealth) {
    let app: ManagedApp
    do { app = try managedApp(args) } catch {
        // An app the daemon quit over its audio is gone from the registry; say why.
        if let p = args.int("pid"), let s = failedStatus(pid_t(p)) {
            throw CLIError("pid \(p) is gone: backstage quit it because its audio couldn't be muted (\(s.reason ?? "tap failed"))")
        }
        throw error
    }
    if let refusal = app.audioMode.inspectionRefusal(app.pid) { throw CLIError(refusal) }
    let health = try requireAudioCapture()
    guard let s = liveStatus(app) else { throw CLIError("the daemon hasn't published audio for pid \(app.pid) yet; retry") }
    if s.tap == "failed" {
        throw CLIError("audio tap failed for pid \(app.pid): \(s.reason ?? "unknown"); backstage is quitting the app")
    }
    return (app, s, health)
}

func cmdAudio(_ args: Args) throws -> [String: Any] {
    if args.pos(0) == "record" { return try cmdAudioRecord(args) }
    let (app, s, health) = try audioTarget(args)
    let now = audioClock()
    var out: [String: Any] = [
        "pid": app.pid, "tap": s.tap, "processes": s.processes, "ioRunning": s.ioRunning, "playing": s.playing,
        "floorDb": health.floorDb, "time": rounded(now, 1000), "sounds": s.sounds.map(soundDict),
    ]
    if let v = s.peakDb { out["peakDb"] = rounded(v) }
    if let v = s.rmsDb { out["rmsDb"] = rounded(v) }
    if let v = s.sampleRate { out["sampleRate"] = v }
    if let v = s.channels { out["channels"] = v }
    if let v = s.outputChannels, v > 2 { out["outputChannels"] = v; out["levelGainDb"] = rounded(s.levelGainDb ?? 0) }
    if let ms = s.sightToMuteMs, !ms.isEmpty { out["sightToMuteMs"] = ms.map { rounded($0, 100) } }
    if s.playing || s.sounds.contains(where: { $0.start + $0.seconds >= now - 1 }), let ring = s.ring,
       let snap = readRing(URL(fileURLWithPath: ring), seconds: 1, endingBy: now, forFrequency: true),
       let hz = dominantFrequency(snap) {
        out["hz"] = hz.rounded()
    }
    return out
}

/// `audio record`: a WAV of the last N seconds (default and maximum 15) of the app's muted output,
/// from the ring the daemon publishes. The ring is a continuous timeline that ends at its newest
/// frame (pauses in output are stored as silence), so the WAV ends where the app's output last
/// ran: now while output runs, or when it stopped. The samples are the tap's stereo mixdown as
/// tapped (float32), without the multichannel compensation `audio`'s levels get.
func cmdAudioRecord(_ args: Args) throws -> [String: Any] {
    let (app, s, _) = try audioTarget(args)
    let seconds: Double
    if let value = args.opt("seconds") {
        guard let duration = Double(value), duration.isFinite, duration > 0 else {
            throw CLIError("--seconds needs a finite duration greater than zero")
        }
        seconds = min(duration, audioRingSeconds)
    } else {
        seconds = audioRingSeconds
    }
    let me = try Session.current().id
    let outPath: String
    if let given = args.opt("o") ?? args.opt("out") {
        guard ["wav", "wave"].contains((given as NSString).pathExtension.lowercased()) else {
            throw CLIError("audio record writes a WAV file: give an output path ending in .wav")
        }
        outPath = (given as NSString).expandingTildeInPath
    } else {
        let folder = Paths.shots.appendingPathComponent(Session.fileKey(me))
        try Paths.ensureDirectory(folder)
        outPath = folder.appendingPathComponent("audio-\(UUID().uuidString).wav").path
    }
    guard let ring = s.ring, FileManager.default.fileExists(atPath: ring) else {
        let why = s.tap == "armed" ? "it hasn't used Core Audio yet" : "its audio output hasn't run since launch"
        throw CLIError("nothing to record: pid \(app.pid) hasn't played any sound (\(why)). Make it play first (`backstage wait --sound` tells you when it does)")
    }
    guard let snap = readRing(URL(fileURLWithPath: ring), seconds: seconds) else {
        throw CLIError("couldn't read pid \(app.pid)'s audio ring (\(ring)): it changed while being read or was removed; retry")
    }
    guard snap.frames > 0 else { throw CLIError("nothing to record: pid \(app.pid)'s audio ring is still empty; retry once it plays") }
    let out = URL(fileURLWithPath: outPath)
    do {
        try writeWAV(snap, to: out)
    } catch {
        throw CLIError("couldn't write \(out.path): \(error.localizedDescription)")
    }
    let length = Double(snap.frames) / snap.sampleRate
    var result: [String: Any] = [
        "ok": true, "pid": app.pid, "path": out.path, "seconds": rounded(length, 1000), "sampleRate": snap.sampleRate,
        "channels": snap.channels, "format": "float32", "start": rounded(snap.endUptime - length, 1000), "end": rounded(snap.endUptime, 1000),
    ]
    if snap.levelGain > 1.0001 { result["levelGainDb"] = rounded(20 * log10(snap.levelGain)) }
    return result
}

/// A WAV of 32-bit float samples (WAVE_FORMAT_IEEE_FLOAT, with the `fact` chunk non-PCM formats need).
private func wavHeader(sampleCount: Int, sampleRate: Double, channels: Int) -> Data {
    var d = Data()
    func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = sampleCount * 4
    d.reserveCapacity(58)
    tag("RIFF"); u32(UInt32(50 + bytes)); tag("WAVE")
    tag("fmt "); u32(18)
    u16(3); u16(UInt16(channels)); u32(UInt32(sampleRate.rounded()))
    u32(UInt32(sampleRate.rounded()) * UInt32(channels) * 4); u16(UInt16(channels * 4)); u16(32); u16(0)
    tag("fact"); u32(4); u32(UInt32(sampleCount / channels))
    tag("data"); u32(UInt32(bytes))
    return d
}

/// Publish only after both the header and payload have been written to a sibling file.
private func writeWAV(_ snap: RingSnapshot, to url: URL) throws {
    func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".backstage-audio-\(UUID())")
    var existing = stat()
    let existingFile = lstat(url.path, &existing) == 0 && existing.st_mode & S_IFMT == S_IFREG
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, existingFile ? 0o600 : 0o666)
    guard fd >= 0 else { throw posixError() }
    defer { unlink(temporary.path) }

    func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var written = 0
        while written < bytes.count {
            let count = write(fd, base + written, bytes.count - written)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw count == 0 ? POSIXError(.EIO) : posixError() }
            written += count
        }
    }
    do {
        let header = wavHeader(sampleCount: snap.samples.count, sampleRate: snap.sampleRate, channels: snap.channels)
        try header.withUnsafeBytes(writeAll)
        try snap.samples.withUnsafeBytes(writeAll) // Float32 on Macs already has WAV byte order.
        if existingFile, fchmod(fd, existing.st_mode & 0o777) != 0 { throw posixError() }
    } catch {
        close(fd)
        throw error
    }
    guard close(fd) == 0, rename(temporary.path, url.path) == 0 else { throw posixError() }
}

private func failedStatus(_ pid: pid_t) -> AudioAppStatus? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: AudioFiles.dir.path),
          let me = try? Session.current().id else { return nil }
    return names.filter { $0.hasPrefix("\(pid)-") && $0.hasSuffix(".json") }
        .compactMap { readJSON(AudioFiles.dir.appendingPathComponent($0), AudioAppStatus.self) }
        .first { $0.tap == "failed" && Session.sameID($0.session, me) }
}

/// Failed taps of this session whose apps the daemon has quit (kept for 10 minutes), for `list`.
func recentAudioFailures(session: String, live: Set<Int32>) -> [[String: Any]] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: AudioFiles.dir.path) else { return [] }
    return names.filter { $0.hasSuffix(".json") && $0.first?.isNumber == true }
        .compactMap { readJSON(AudioFiles.dir.appendingPathComponent($0), AudioAppStatus.self) }
        .filter { $0.tap == "failed" && Session.sameID($0.session, session) && !live.contains($0.pid) }
        .map { ["pid": $0.pid, "name": $0.name, "tap": "failed", "reason": $0.reason ?? "tap failed"] }
}

func cmdWaitSound(_ args: Args) throws -> [String: Any] {
    let app = try managedApp(args)
    if let refusal = app.audioMode.inspectionRefusal(app.pid) { throw CLIError(refusal) }
    let health = try requireAudioCapture()
    let gone = args.has("gone")
    let since = args.double("since")
    let minDb = args.double("min-db")
    let timeout = args.double("timeout") ?? 10
    let began = audioClock()
    let from = since ?? began
    let birth = app.processStart ?? app.liveProcessBirth
    var last: AudioAppStatus?
    func counts(_ s: AudioSound) -> Bool { minDb.map { s.peakDb >= $0 } ?? true }
    let found: AudioSound?? = try waitFor(timeout: timeout, interval: 0.03) {
        guard let birth, processBirth(app.pid) == birth else {
            throw CLIError(audioFailure(app.pid, birth) ?? "app \(app.pid) exited while waiting for sound")
        }
        guard let s = readAudioStatus(app.pid, birth) else { return nil }
        last = s
        if s.tap == "failed" { throw CLIError("audio tap failed for pid \(app.pid): \(s.reason ?? "unknown"); backstage is quitting the app") }
        if gone {
            if s.playing || s.sounds.contains(where: { $0.ongoing }) { return nil }
            return .some(s.sounds.last { !$0.ongoing && $0.start + $0.seconds >= (since ?? -Double.infinity) })
        }
        let hit = s.sounds.last { counts($0) && ($0.start >= from || (since == nil && $0.ongoing)) }
        return hit.map { .some($0) }
    }
    let seconds = rounded(audioClock() - began, 100)
    guard let found else {
        var why: String
        if gone {
            why = "sound still playing"
        } else if let s = last {
            let candidates = s.sounds.filter { $0.start >= from || (since == nil && $0.ongoing) }
            if let loudest = candidates.max(by: { $0.peakDb < $1.peakDb }), let minDb {
                why = "loudest sound peaked at \(rounded(loudest.peakDb)) dBFS, below --min-db \(rounded(minDb))"
            } else if !s.ioRunning && candidates.isEmpty {
                why = "no audio output running"
            } else if let peak = s.peakDb, peak <= -150 {
                why = "output running but silent (digital silence)"
            } else if let peak = s.peakDb {
                why = "output running but silent (peak \(rounded(peak)) dBFS, below the \(rounded(health.floorDb)) dBFS floor)"
            } else {
                why = "output running but silent"
            }
        } else {
            why = "the daemon published no audio state for this app"
        }
        throw CLIError("timed out after \(timeout)s waiting for \(gone ? "sound to stop" : "sound"): \(why)")
    }
    var out: [String: Any] = ["ok": true, "seconds": seconds, "time": rounded(audioClock(), 1000)]
    out["sound"] = found.map(soundDict) ?? NSNull()
    return out
}

// MARK: - doctor

/// Ask the daemon to run its audio self-test (it plays an inaudible probe from its own process,
/// muted by its own tap, and checks the tap captured it). The first run raises the System Audio
/// Recording prompt for the daemon's host, so doctor is the way to ask for it.
func audioDoctor() -> [String: Any] {
    guard audioSupported() else { return ["muting": "unavailable", "reason": "audio muting needs macOS 14.2 or later"] }
    let d: DaemonInfo
    do { d = try ensureDaemon() } catch { return ["error": "\(error)"] }
    var out = audioSummary(d)
    guard d.audio == true else { return out }
    let id = UUID().uuidString
    do {
        try Paths.ensureDirectory(AudioFiles.dir)
        try Data().write(to: AudioFiles.selfTestRequest(id))
    } catch {
        out["selfTest"] = ["error": "couldn't ask the daemon: \(error)"]
        return out
    }
    var prompted = false
    let result: AudioSelfTestResult? = waitFor(timeout: 60, interval: 0.1) {
        guard let r = readJSON(AudioFiles.selfTestResult(id), AudioSelfTestResult.self) else { return nil }
        if r.state == "prompting" && !prompted {
            prompted = true
            eprint("backstage: waiting for the System Audio Recording prompt (\(readAudioHealth()?.host?.name ?? "daemon host")) to be answered…")
        }
        return r.state == "done" ? r : nil
    }
    try? FileManager.default.removeItem(at: AudioFiles.selfTestRequest(id))
    try? FileManager.default.removeItem(at: AudioFiles.selfTestResult(id))
    guard let result else {
        out["selfTest"] = ["error": "the daemon didn't finish the audio self-test within 60s"]
        return out
    }
    var test: [String: Any] = ["captured": result.captured ?? false, "expectedDb": result.expectedDb, "hz": result.hz]
    if let v = result.levelDb { test["levelDb"] = rounded(v) }
    if let v = result.device { test["device"] = v }
    if let v = result.error { test["error"] = v }
    if let v = result.ioSetupMs { test["ioSetupMs"] = rounded(v) }
    out["selfTest"] = test
    out = audioSummary(d).merging(["selfTest": test]) { _, new in new }
    if let p = result.permission { out["capture"] = p }
    return out
}

/// The daemon's audio state for `status`/`doctor`.
func audioSummary(_ d: DaemonInfo?) -> [String: Any] {
    guard audioSupported() else { return ["muting": "unavailable", "reason": "audio muting needs macOS 14.2 or later"] }
    guard let d else { return ["daemon": "not running"] }
    guard let ok = d.audio else { return ["muting": "unavailable", "reason": "the running daemon is from an older build without audio muting"] }
    var out: [String: Any] = ["muting": ok ? "ok" : "unavailable"]
    if !ok { out["reason"] = d.audioReason ?? "unknown" }
    if let h = readAudioHealth() {
        out["capture"] = h.capture
        out["floorDb"] = h.floorDb
        if let host = h.host { out["host"] = ["pid": host.pid, "name": host.name, "path": host.path ?? ""] }
    }
    return out
}

/// Problems to report for the audio section (doctor) or warnings (status).
func audioProblems(_ audio: [String: Any]) -> [String] {
    var problems: [String] = []
    if audio["muting"] as? String == "unavailable" {
        problems.append("Audio muting is unavailable (\(audio["reason"] as? String ?? "unknown")), so `launch` refuses to start apps.")
    }
    let test = audio["selfTest"] as? [String: Any]
    if audio["capture"] as? String == "not granted" || (test != nil && test?["captured"] as? Bool != true) {
        let health = readAudioHealth()
        var line = "System Audio Recording isn't working for \(hostDescription(health)): apps are still muted, but `audio` and `wait --sound` can't measure them. \(audioGrantHelp(health))."
        if let e = test?["error"] as? String { line += " Self-test: \(e)." }
        problems.append(line)
    }
    return problems
}

// MARK: - ring reader (format documented in CBackstageAudio.h)

struct RingSnapshot {
    var sampleRate: Double
    var channels: Int
    var endUptime: Double
    var levelGain: Double = 1      // applied to levels, not to these samples
    var samples: [Float]           // interleaved
    var frames: Int { channels > 0 ? samples.count / channels : 0 }
}

/// The last `seconds` of a published ring, cut off at `endingBy` (audio clock): frames after
/// the newest one are silence and aren't included. A frequency read copies only the trailing FFT window.
func readRing(_ url: URL, seconds: Double, endingBy: Double? = nil, forFrequency: Bool = false) -> RingSnapshot? {
    guard seconds.isFinite, seconds > 0, endingBy?.isFinite != false else { return nil }
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? fh.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 64 else { return nil }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard (try? fh.seek(toOffset: offset)) != nil, let data = try? fh.read(upToCount: count),
              data.count == count else { return nil }
        return data
    }
    func header() -> (rate: Double, ch: Int, cap: Int, written: UInt64, end: Double, gain: Double, sequence: UInt64)? {
        guard let before = read(56, 8), let data = read(0, 64), let after = read(56, 8),
              before == after, data.prefix(4) == Data("BSAR".utf8) else { return nil }
        return data.withUnsafeBytes { raw in
            let sequence = raw.loadUnaligned(fromByteOffset: 56, as: UInt64.self)
            guard raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 1,
                  sequence & 1 == 0, before.withUnsafeBytes({ $0.loadUnaligned(as: UInt64.self) }) == sequence else { return nil }
            return (raw.loadUnaligned(fromByteOffset: 8, as: Double.self), Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)),
                    Int(raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)), raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self),
                    raw.loadUnaligned(fromByteOffset: 40, as: Double.self), raw.loadUnaligned(fromByteOffset: 48, as: Double.self), sequence)
        }
    }
    for _ in 0..<6 {
        guard let h = header() else { continue }
        guard h.rate.isFinite, h.rate >= 1, h.rate <= 768_000, h.ch > 0, h.ch <= 32,
              h.cap > 0, h.cap <= Int(audioRingSeconds * h.rate), h.end.isFinite, h.end >= 0,
              Int64(h.cap) <= (info.st_size - 64) / Int64(h.ch * 4) else { return nil }
        let gain = h.gain.isFinite && h.gain > 0 ? h.gain : 1
        let available = Int(min(h.written, UInt64(h.cap)))
        let cutoff = endingBy ?? h.end
        let skipped = Int(min(Double(available), (max(0, h.end - cutoff) * h.rate).rounded(.up)))
        let length = min(seconds, audioRingSeconds) - max(0, cutoff - h.end)
        let windowFrames = min(available - skipped, Int((max(0, length) * h.rate).rounded()))
        let want = forFrequency ? frequencyWindowFrames(windowFrames) : windowFrames
        let end = h.end - Double(skipped) / h.rate
        guard want > 0 else { return RingSnapshot(sampleRate: h.rate, channels: h.ch, endUptime: end, levelGain: gain, samples: []) }
        let firstFrame = Int((h.written - UInt64(skipped + want)) % UInt64(h.cap))
        let firstCount = min(want, h.cap - firstFrame) * h.ch * MemoryLayout<Float>.stride
        var samples = [Float](unsafeUninitializedCapacity: want * h.ch) { buffer, initializedCount in
            initializedCount = 0
            let bytes = UnsafeMutableRawBufferPointer(buffer)

            func readSamples(from offset: Int, into start: Int, count: Int) -> Bool {
                guard let base = bytes.baseAddress else { return count == 0 }
                var copied = 0
                while copied < count {
                    let n = pread(fh.fileDescriptor, base + start + copied, count - copied, off_t(offset + copied))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return false }
                    copied += n
                }
                return true
            }
            guard readSamples(from: 64 + firstFrame * h.ch * MemoryLayout<Float>.stride, into: 0, count: firstCount),
                  readSamples(from: 64, into: firstCount, count: bytes.count - firstCount) else { return }
            initializedCount = buffer.count
        }
        guard !samples.isEmpty, let after = header(), after.rate == h.rate, after.ch == h.ch, after.cap == h.cap,
              after.written >= h.written, after.written - h.written < UInt64(h.cap) else { continue }
        let advanced = Int(after.written - h.written)
        // Older writers leave the marker at zero and publish their count only after copying.
        let legacyInFlight = after.sequence == 0 && (advanced > 0 || audioClock() - after.end <= 0.25)
            ? Int(0.1 * h.rate) : 0
        let lapped = advanced + legacyInFlight - (h.cap - skipped - want)
        if lapped > 0 {
            guard lapped < want else { continue }
            samples.removeFirst(lapped * h.ch)
        }
        return RingSnapshot(sampleRate: h.rate, channels: h.ch, endUptime: end, levelGain: gain, samples: samples)
    }
    return nil
}

private func frequencyWindowFrames(_ available: Int) -> Int {
    guard available >= 2048 else { return 0 }
    var frames = 2048
    while frames * 2 <= available && frames < 65536 { frames *= 2 }
    return frames
}

/// The strongest frequency (Hann-windowed FFT, parabolic interpolation). Useful for tones.
func dominantFrequency(_ snap: RingSnapshot) -> Double? {
    let frames = snap.frames
    let n = frequencyWindowFrames(frames)
    guard n > 0 else { return nil }
    var mono = [Float](repeating: 0, count: n)
    let start = frames - n
    for i in 0..<n {
        var s: Float = 0
        for c in 0..<snap.channels { s += snap.samples[(start + i) * snap.channels + c] }
        mono[i] = s / Float(snap.channels)
    }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(n))
    let log2n = vDSP_Length(log2(Double(n)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }
    var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
    var mags = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            mono.withUnsafeBufferPointer { mp in
                mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            split.imagp[0] = 0  // vDSP packs the Nyquist value with the DC bin.
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
        }
    }
    let lowest = max(1, Int(20 * Double(n) / snap.sampleRate))
    guard lowest < n / 2 - 1 else { return nil }
    var k = lowest
    for i in lowest..<(n / 2 - 1) where mags[i] > mags[k] { k = i }
    guard mags[k] > 0 else { return nil }
    let a = log(Double(max(mags[k - 1], 1e-30))), b = log(Double(mags[k])), c = log(Double(max(mags[k + 1], 1e-30)))
    let denominator = a - 2 * b + c
    let delta = denominator != 0 ? 0.5 * (a - c) / denominator : 0
    return (Double(k) + delta) * snap.sampleRate / Double(n)
}
