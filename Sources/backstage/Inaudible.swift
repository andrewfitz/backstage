import Foundation
import Security

/// How `launch` handles an app's sound (user decision: audio inspection is opt-in).
/// - `inaudible`: the app makes itself inaudible from inside (an injected library sets
///   kAudioHardwarePropertyProcessIsAudible = 0), so nothing it plays reaches the speakers,
///   screen sharing, remote desktop (Parsec), global taps or recordings. Also muted by a tap.
///   The default for dev builds and test runners that accept injection.
/// - `muted`: a muted process tap keeps it off the Mac's outputs, but system-wide captures still
///   carry its sound. Not measured. The default for everything else (signed, hardened, Apple).
/// - `metered`: `launch --audio`. Muted like `muted`, and measured (`audio`, `wait --sound`,
///   `audio record`, the menu bar meter). Records from before modes existed are metered.
enum AudioMode: String, Codable {
    case inaudible, muted, metered

    init(_ raw: String?) { self = raw.flatMap(AudioMode.init(rawValue:)) ?? .metered }
    var metered: Bool { self == .metered }

    /// Why the audio commands refuse an app launched in this mode, or nil when they don't.
    func inspectionRefusal(_ pid: pid_t) -> String? {
        switch self {
        case .metered: return nil
        case .inaudible: return "pid \(pid) was launched inaudible (nothing it plays is audible anywhere, so there's nothing to measure); relaunch with --audio to inspect its sound"
        case .muted: return "pid \(pid) was launched without --audio, so its sound isn't measured; relaunch with --audio to inspect its sound"
        }
    }
}

enum InaudibleLibrary {
    static let fileName = "libbackstage-inaudible.dylib"
    static let ackKey = "BACKSTAGE_INAUDIBLE_ACK"

    /// The installed library: next to this executable (the build directory, the test copies in
    /// /tmp/backstage-test-*), else in ../lib/backstage (`make install`). BACKSTAGE_INAUDIBLE_DYLIB
    /// overrides it (empty: none, for tests).
    static func locate() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BACKSTAGE_INAUDIBLE_DYLIB"] {
            guard !override.isEmpty, FileManager.default.isReadableFile(atPath: override) else { return nil }
            return URL(fileURLWithPath: override).resolvingSymlinksInPath()
        }
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let dir = exe.deletingLastPathComponent()
        for candidate in [dir.appendingPathComponent(fileName),
                          dir.appendingPathComponent("../lib/backstage/\(fileName)").standardizedFileURL]
        where FileManager.default.isReadableFile(atPath: candidate.path) {
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    static func ackFile(_ launchID: String) -> URL { Paths.appLogs.appendingPathComponent("\(launchID).inaudible") }
}

/// What `launch` will do about an app's sound.
struct AudioPlan {
    var mode: AudioMode
    /// Why the app isn't inaudible (or what --audio means), for launch's `audioReason`.
    var reason: String?
    var library: URL?
    let forced: Bool
}

/// `--audio`: metered. `--inaudible`: inaudible or an error. Neither: inaudible when the target
/// accepts the library, else muted.
func planAudio(_ args: Args, executable: URL, name: String) throws -> AudioPlan {
    let wantsAudio = args.has("audio"), forced = args.has("inaudible")
    if wantsAudio && forced { throw CLIError("--audio and --inaudible exclude each other") }
    if wantsAudio {
        return AudioPlan(mode: .metered, reason: "--audio: muted on this Mac's outputs and measured; screen sharing, remote desktop and recordings of the Mac can still hear it",
                         library: nil, forced: false)
    }
    guard let library = InaudibleLibrary.locate() else {
        let missing = "\(InaudibleLibrary.fileName) wasn't found next to the backstage binary or in ../lib/backstage (reinstall with `make install`)"
        if forced { throw CLIError("can't launch \(name) inaudible: \(missing)") }
        return AudioPlan(mode: .muted, reason: "\(missing); muted on this Mac's outputs only, so screen sharing and recordings can still hear it",
                         library: nil, forced: false)
    }
    let check = inaudibleEligibility(executable, library: library)
    if check.eligible { return AudioPlan(mode: .inaudible, reason: nil, library: library, forced: forced) }
    if forced { throw CLIError("can't launch \(name) inaudible: \(check.detail)") }
    return AudioPlan(mode: .muted, reason: "\(check.detail); muted on this Mac's outputs only, so screen sharing and recordings can still hear it",
                     library: nil, forced: false)
}

// MARK: - eligibility

/// Whether dyld will load the library into the process `executable` starts, and whether the
/// target is a dev build or test runner rather than released software (user decision: signed,
/// hardened and Apple apps keep the muted tap). Checked before launch; confirmed after it.
struct InaudibleEligibility {
    let executable: URL
    let eligible: Bool
    /// Why not, or what kind of target it is ("ad-hoc signed", …).
    let detail: String
}

func inaudibleEligibility(_ executable: URL, library: URL) -> InaudibleEligibility {
    let exe = executable.resolvingSymlinksInPath()
    func no(_ why: String) -> InaudibleEligibility { InaudibleEligibility(executable: exe, eligible: false, detail: why) }
    let path = exe.path
    guard let macho = MachOSummary(exe) else {
        if let head = try? FileHandle(forReadingFrom: exe) {
            defer { try? head.close() }
            if let bytes = try? head.read(upToCount: 2), bytes == Data("#!".utf8) {
                return no("\(exe.lastPathComponent) is a script: backstage cannot verify that its interpreter accepts DYLD_INSERT_LIBRARIES")
            }
        }
        return no("\(exe.lastPathComponent) isn't a Mach-O executable backstage can inspect")
    }
    for prefix in ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"] where path.hasPrefix(prefix) && !path.hasPrefix("/usr/local/") {
        return no("\(path) is protected by System Integrity Protection (dyld ignores DYLD_INSERT_LIBRARIES for it)")
    }
    var info = stat()
    if stat(path, &info) == 0, info.st_mode & (S_ISUID | S_ISGID) != 0 {
        return no("\(exe.lastPathComponent) is setuid or setgid (dyld ignores DYLD_INSERT_LIBRARIES for it)")
    }
    guard let arch = macho.launchArchitecture else { return no("\(exe.lastPathComponent) has no slice this Mac runs") }
    let libraryArchs = MachOSummary(library)?.architectures ?? []
    guard libraryArchs.contains(arch) else {
        return no("the injected library has no \(arch) slice (it has \(libraryArchs.joined(separator: ", ")))")
    }
    if macho.restrictSegment { return no("\(exe.lastPathComponent) has a __RESTRICT segment (dyld ignores DYLD_INSERT_LIBRARIES for it)") }

    let signing = CodeSigning(exe)
    guard signing.signed else { return InaudibleEligibility(executable: exe, eligible: true, detail: "unsigned") }
    if signing.platform { return no("\(exe.lastPathComponent) is an Apple platform binary") }
    if let distribution = signing.distribution, !signing.getTaskAllow {
        return no("\(exe.lastPathComponent) is signed for distribution (\(distribution)), not a dev build")
    }
    let flags = signing.flags
    if flags & 0x800 != 0 { return no("\(exe.lastPathComponent) is signed with the restrict flag (dyld ignores DYLD_INSERT_LIBRARIES for it)") }
    let allowDyld = signing.entitlement("com.apple.security.cs.allow-dyld-environment-variables")
    let anyLibrary = signing.entitlement("com.apple.security.cs.disable-library-validation")
    if flags & 0x10000 != 0, !(allowDyld && anyLibrary) {
        return no("\(exe.lastPathComponent) uses the hardened runtime without the allow-dyld-environment-variables and disable-library-validation entitlements, so dyld won't load the library")
    }
    if flags & 0x2000 != 0, !anyLibrary { return no("\(exe.lastPathComponent) enforces library validation, so dyld won't load the (ad-hoc signed) library") }
    let kind = flags & 0x2 != 0 ? "ad-hoc signed" : signing.getTaskAllow ? "development signed (get-task-allow)" : "signed"
    return InaudibleEligibility(executable: exe, eligible: true, detail: kind)
}

/// The architectures in a Mach-O file (thin or universal), and whether any slice has a
/// __RESTRICT segment.
struct MachOSummary {
    var architectures: [String] = []
    var restrictSegment = false

    init?(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? fh.seek(toOffset: offset)) != nil, let d = try? fh.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        func u32(_ d: Data, _ at: Int, big: Bool) -> UInt32 {
            let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
            return big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
        }
        guard let head = read(0, 8) else { return nil }
        let magic = u32(head, 0, big: true)
        var slices: [UInt64] = []
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {          // FAT_MAGIC, FAT_MAGIC_64
            let count = Int(u32(head, 4, big: true))
            let entry = magic == 0xCAFEBABE ? 20 : 32
            guard count > 0, count < 32, let table = read(8, count * entry) else { return nil }
            for i in 0..<count {
                let base = i * entry
                if magic == 0xCAFEBABE { slices.append(UInt64(u32(table, base + 8, big: true))) }
                else {
                    let hi = UInt64(u32(table, base + 8, big: true)), lo = UInt64(u32(table, base + 12, big: true))
                    slices.append(hi << 32 | lo)
                }
            }
        } else {
            slices = [0]
        }
        for offset in slices {
            guard let header = read(offset, 32), u32(header, 0, big: false) == 0xFEEDFACF else { continue }   // MH_MAGIC_64
            let cpu = u32(header, 4, big: false), sub = u32(header, 8, big: false) & 0x00FF_FFFF
            switch cpu {
            case 0x0100_000C: architectures.append(sub == 2 ? "arm64e" : "arm64")
            case 0x0100_0007: architectures.append("x86_64")
            default: architectures.append("cpu \(cpu)")
            }
            let size = Int(u32(header, 20, big: false))
            guard size > 0, size < 4 << 20, offset <= UInt64.max - 32,
                  let commands = read(offset + 32, size) else { continue }
            var cursor = 0
            for _ in 0..<u32(header, 16, big: false) {
                guard cursor <= size - 8 else { break }
                let command = u32(commands, cursor, big: false)
                let length = Int(u32(commands, cursor + 4, big: false))
                guard length >= 8, length <= size - cursor else { break }
                if command == 0x19, length >= 72,
                   commands[(cursor + 8)..<(cursor + 19)] == Data("__RESTRICT\0".utf8) {
                    restrictSegment = true
                    break
                }
                cursor += length
            }
        }
        if architectures.isEmpty { return nil }
    }

    /// The slice this Mac runs: native arm64 (the plain ABI before arm64e) on Apple silicon, else
    /// x86_64 (under Rosetta there).
    var launchArchitecture: String? {
        #if arch(arm64)
        for a in ["arm64", "arm64e", "x86_64"] where architectures.contains(a) { return a }
        return nil
        #else
        return architectures.contains("x86_64") ? "x86_64" : nil
        #endif
    }
}

/// The parts of a code signature that decide whether dyld honours DYLD_INSERT_LIBRARIES.
struct CodeSigning {
    var signed = false
    var flags: UInt32 = 0
    var platform = false
    var entitlements: [String: Any] = [:]
    /// "Apple", "Developer ID" or "Mac App Store": released software.
    var distribution: String?

    var getTaskAllow: Bool { entitlement("com.apple.security.get-task-allow") }
    func entitlement(_ key: String) -> Bool { (entitlements[key] as? Bool) == true }

    init(_ url: URL) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return }
        var raw: CFDictionary?
        let what = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, what, &raw) == errSecSuccess, let info = raw as? [String: Any] else { return }
        guard info[kSecCodeInfoIdentifier as String] != nil else { return }   // unsigned
        signed = true
        flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        platform = ((info[kSecCodeInfoPlatformIdentifier as String] as? NSNumber)?.intValue ?? 0) != 0
        entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        guard flags & 0x2 == 0 else { return }   // ad-hoc: no certificate
        let quick = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        for (name, requirement) in [("Apple", "anchor apple"),
                                    ("Developer ID", "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]"),
                                    ("Mac App Store", "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]")] {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { continue }
            if SecStaticCodeCheckValidity(code, quick, req) == errSecSuccess { distribution = name; break }
        }
    }
}

// MARK: - after launch

/// The launched process made itself inaudible: its acknowledgement says the set succeeded, or
/// (when it couldn't write one, e.g. a sandboxed app) the library is mapped into it. Returns
/// nil when confirmed, else why not.
func confirmInaudible(pid: pid_t, launchID: String, library: URL, timeout: Double = 2) -> String? {
    let ack = InaudibleLibrary.ackFile(launchID)
    defer { try? FileManager.default.removeItem(at: ack) }
    var lastError: Int32?
    let confirmed: Bool = waitFor(timeout: timeout, interval: 0.02) {
        guard let text = try? String(contentsOf: ack, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 2, pid_t(parts[0]) == pid, let status = Int32(parts[1]) else { return nil }
        if status == 0 { return true }
        lastError = status
        return nil   // it retries for a while
    } ?? false
    if confirmed { return nil }
    if let lastError { return "the app couldn't make itself inaudible: Core Audio returned \(fourCC(lastError))" }
    if processMaps(pid, library) { return nil }
    return "the library wasn't loaded into pid \(pid) (dyld ignored DYLD_INSERT_LIBRARIES)"
}

/// A file is mapped into the process (its image list, read from the outside).
func processMaps(_ pid: pid_t, _ file: URL) -> Bool {
    let target = file.resolvingSymlinksInPath().path
    var expected = stat()
    guard stat(target, &expected) == 0 else { return false }
    var info = proc_regionwithpathinfo()
    var address: UInt64 = 0
    let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
    for _ in 0..<200_000 {
        guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size) == size else { return false }
        if info.prp_vip.vip_vi.vi_stat.vst_ino == expected.st_ino,
           info.prp_vip.vip_vi.vi_stat.vst_dev == UInt32(bitPattern: expected.st_dev) { return true }
        let (next, overflow) = info.prp_prinfo.pri_address.addingReportingOverflow(info.prp_prinfo.pri_size)
        guard !overflow, next > address else { return false }
        address = next
    }
    return false
}
