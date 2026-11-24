import Foundation
import CoreAudio
import AudioToolbox

/// Small synchronous Core Audio (HAL) helpers. Every call may block on coreaudiod, so the daemon
/// makes them only on its audio queues, never on the main thread.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var a = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // Process objects (audio clients)
    static func processObjects() -> [AudioObjectID] { ids(system, kAudioHardwarePropertyProcessObjectList) }
    static func pid(of process: AudioObjectID) -> pid_t? { get(process, kAudioProcessPropertyPID, pid_t(-1)).flatMap { $0 > 0 ? $0 : nil } }
    static func isRunningOutput(_ process: AudioObjectID) -> Bool { (get(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0 }
    static func outputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        ids(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
    }
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object
    }

    // Devices
    static func devices() -> [AudioObjectID] { ids(system, kAudioHardwarePropertyDevices) }
    static func defaultOutput() -> AudioObjectID? { get(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 } }
    static func name(_ device: AudioObjectID) -> String { string(device, kAudioObjectPropertyName) ?? "?" }
    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func nominalRate(_ device: AudioObjectID) -> Double { get(device, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0 }
    static func channels(_ device: AudioObjectID, input: Bool) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func isBuiltIn(_ device: AudioObjectID) -> Bool {
        get(device, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
    }

    /// An output device with no input streams. Attaching IO to a device that has inputs makes
    /// coreaudiod ask TCC for the Microphone on macOS 27 (measured), even for output only.
    /// Prefers the default output, then built-in devices.
    static func outputOnlyDevice() -> AudioObjectID? {
        let all = devices().filter { channels($0, input: false) > 0 && channels($0, input: true) == 0 }
        if let d = defaultOutput(), all.contains(d) { return d }
        return all.first(where: isBuiltIn) ?? all.first
    }

    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        get(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    }
}

/// An OSStatus as its four characters when printable ('!obj'), else the number.
func fourCC(_ status: OSStatus) -> String {
    let u = UInt32(bitPattern: status)
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) { return "'\(s)'" }
    return "\(status)"
}

private let machTimebase: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1e9
}()

/// Seconds per mach_absolute_time tick.
var machSecondsPerTick: Double { machTimebase }
/// The audio clock: mach_absolute_time in seconds (system uptime, not counting sleep). `audio`'s
/// `time`, `--since` and every sound's `start` use it.
func audioClock() -> Double { Double(mach_absolute_time()) * machTimebase }
func hostTicksToSeconds(_ ticks: UInt64) -> Double { Double(ticks) * machTimebase }

/// The process macOS holds responsible for `pid` (private libsystem call, the one TCC uses).
func responsiblePid(_ pid: pid_t) -> pid_t? {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    struct Holder { static let fn: Fn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: Fn.self) } }
    guard let fn = Holder.fn else { return nil }
    let r = fn(pid)
    return r > 0 ? r : nil
}

func processPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

/// TCC's private preflight for this process's responsible host: 0 granted, 1 denied, 2 not
/// decided (measured: granted 0, never asked 2). Never prompts. A hint only: the verdict on
/// capture permission is the self-test capturing its probe.
func tccPreflight(_ service: String) -> Int32? {
    typealias Fn = @convention(c) (CFString, CFDictionary?) -> Int32
    struct Holder {
        static let fn: Fn? = {
            guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
                  let s = dlsym(h, "TCCAccessPreflight") else { return nil }
            return unsafeBitCast(s, to: Fn.self)
        }()
    }
    return Holder.fn?(service as CFString, nil)
}

/// The inaudible probe: a sine of at least 18 kHz, at most -60 dBFS, with 10 ms raised-cosine
/// ramps, at most 2 s. Used by the daemon's self-test.
struct ProbeTone {
    let hz: Double, amplitude: Double, frames: Int, rate: Double, ramp: Int
    init(hz: Double, dbfs: Double, seconds: Double, rate: Double) {
        precondition(hz >= 18000 && hz < rate / 2, "probe tones must be at least 18 kHz and below Nyquist")
        precondition(dbfs <= -60, "probe tones must be at most -60 dBFS")
        precondition(seconds <= 2, "probe bursts must be at most 2 s")
        self.hz = hz; self.amplitude = pow(10, dbfs / 20); self.rate = rate
        frames = Int(seconds * rate); ramp = max(1, Int(0.010 * rate))
    }
    func sample(_ i: Int) -> Float {
        guard i >= 0, i < frames else { return 0 }
        var g = 1.0
        if i < ramp { g = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(ramp)) }
        let fromEnd = frames - 1 - i
        if fromEnd < ramp { g = min(g, 0.5 - 0.5 * cos(Double.pi * Double(fromEnd) / Double(ramp))) }
        return Float(amplitude * g * sin(2 * Double.pi * hz * Double(i) / rate))
    }
}

/// Goertzel power at one frequency over a block, as the amplitude in dBFS of a sine there.
struct Goertzel {
    let coeff: Double, window: Int
    var s1 = 0.0, s2 = 0.0, n = 0
    private(set) var best = -200.0
    init(hz: Double, rate: Double) { coeff = 2 * cos(2 * Double.pi * hz / rate); window = max(1, Int(rate / 10)) }
    mutating func feed(_ x: Float) {
        let s = Double(x) + coeff * s1 - s2
        s2 = s1; s1 = s; n += 1
        if n == window {
            let p = s1 * s1 + s2 * s2 - coeff * s1 * s2
            let amp = 2 * max(p, 0).squareRoot() / Double(window)
            best = max(best, amp > 0 ? 20 * log10(amp) : -200)
            s1 = 0; s2 = 0; n = 0
        }
    }
}
