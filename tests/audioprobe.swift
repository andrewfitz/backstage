// Test helper for tests/audio.sh and tests/audio-leak.sh. Runs under the test's own host (not
// through backstage), so it's the measuring instrument, never the app under test.
//   audioprobe devices                  JSON: every device (uid, name, in/out channels, default)
//   audioprobe mic                      the host's Microphone authorization (0 undecided, 2 denied, 3 granted)
//   audioprobe now                      the audio clock (mach_absolute_time in seconds)
//   audioprobe play --device U --hz H --ms M [--delay-ms D] [--again-after-ms D]
//                                       the inaudible probe (>= 18 kHz, -60 dBFS, 10 ms ramps, <= 2 s),
//                                       from the first rendered frame, through a raw HAL IOProc, on
//                                       output channels 1-2 (optionally a second burst after a pause)
//   audioprobe listen --device U --hz H --secs S [--channel N]
//                                       read a loopback device's input: what really reached it
//   audioprobe capture --hz H --secs S [--sck] [--ready FILE]
//                                       what system-wide captures get: an UNMUTED private global tap
//                                       (excluding nothing) and, with --sck, our own ScreenCaptureKit
//                                       stream of the main display with audio (what screen sharing and
//                                       remote desktop such as Parsec use). Needs System Audio Recording
//                                       (the tap) and Screen Recording (--sck) already granted to the
//                                       host: it refuses rather than prompt for either.
// A device with input streams is used only if the host's Microphone access is granted, so
// nothing here can raise a Microphone prompt.
import Foundation
import CoreAudio
import AVFoundation
import ScreenCaptureKit
import CoreMedia

setvbuf(stdout, nil, _IOLBF, 0)
let argv = Array(CommandLine.arguments.dropFirst())
func opt(_ k: String) -> String? { argv.firstIndex(of: "--" + k).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
func emit(_ o: Any) { print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!) }

let system = AudioObjectID(kAudioObjectSystemObject)
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
    return ids
}
func string(_ d: AudioObjectID, _ s: AudioObjectPropertySelector) -> String? {
    var a = addr(s); var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr, let v else { return nil }
    return v.takeRetainedValue() as String
}
func channels(_ d: AudioObjectID, input: Bool) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func scalar<T>(_ d: AudioObjectID, _ s: AudioObjectPropertySelector, _ v: T) -> T {
    var a = addr(s); var v = v; var size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v); return v
}
func audioClock() -> Double {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1e9
}
func device(_ uid: String, micOK: Bool? = nil) -> AudioObjectID {
    guard let d = devices().first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid }) else { fail("no device \(uid)") }
    if channels(d, input: true) > 0 && !(micOK ?? (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)) {
        fail("\(uid) has input streams and this host's Microphone access isn't granted: refusing (it would raise a prompt)")
    }
    return d
}

switch argv.first {
case "devices":
    let def = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    let sys = scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
    emit(devices().map { d -> [String: Any] in
        ["uid": string(d, kAudioDevicePropertyDeviceUID) ?? "", "name": string(d, kAudioObjectPropertyName) ?? "",
         "in": channels(d, input: true), "out": channels(d, input: false), "default": d == def, "system": d == sys]
    })
case "mic":
    print(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
case "now":
    print(String(format: "%.4f", audioClock()))
case "play":
    // The Microphone check comes first, so the timeline starts at the first HAL call, like an app
    // that plays from its first line.
    let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let t0 = audioClock()
    let d = device(opt("device") ?? "", micOK: micOK)   // first HAL call: the process object appears here
    let hz = Double(opt("hz") ?? "18500")!, ms = Double(opt("ms") ?? "300")!
    let rate = scalar(d, kAudioDevicePropertyNominalSampleRate, Float64(48000))
    guard hz >= 18000, hz < rate / 2, ms > 0, ms <= 2000 else { fail("probe must be >= 18 kHz and <= 2 s") }
    if let delay = opt("delay-ms").flatMap(Double.init) { usleep(UInt32(delay * 1000)) }
    let amp = pow(10.0, -60.0 / 20.0), total = Int(ms / 1000 * rate), ramp = Int(0.010 * rate)
    var n = 0, first = 0.0
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, _, _, out, _ in
        if first == 0 { first = audioClock() }
        var frames = 0
        for b in UnsafeMutableAudioBufferListPointer(out) {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(Int(b.mNumberChannels), 1); frames = Int(b.mDataByteSize) / 4 / ch
            for i in 0..<frames {
                let k = n + i
                var g = 0.0
                if k < total { g = min(1, Double(k) / Double(ramp), Double(total - 1 - k) / Double(ramp)); g = 0.5 - 0.5 * cos(Double.pi * g) }
                let s = Float(amp * g * sin(2 * Double.pi * hz * Double(k) / rate))
                for c in 0..<ch { p[i * ch + c] = c < 2 ? s : 0 }
            }
        }
        n += frames
    }
    let start = audioClock()
    AudioDeviceStart(d, proc)
    usleep(UInt32(ms * 1000 + 200_000))
    AudioDeviceStop(d, proc)
    if let again = opt("again-after-ms").flatMap(Double.init) {
        // The same burst again from the same process after a pause, e.g. once its tap's IO stopped.
        usleep(UInt32(again * 1000))
        n = 0
        AudioDeviceStart(d, proc)
        usleep(UInt32(ms * 1000 + 200_000))
        AudioDeviceStop(d, proc)
    }
    let outputEnd = audioClock()   // after the last burst (and its 200 ms tail) stopped
    AudioDeviceDestroyIOProcID(d, proc!)
    if let hold = opt("hold-ms").flatMap(Double.init) { usleep(UInt32(hold * 1000)) }   // stay alive, output stopped
    emit(["pid": getpid(), "processStart": t0, "outputStart": start, "firstRender": first, "frames": total, "outputEnd": outputEnd])
case "listen":
    // Every input channel gets its own detector (`channelToneDb`, the best 100 ms window per
    // channel: finding which input loops an output back). The other fields are for `--channel`
    // (1-based, default 1): a multichannel interface's loopback is often not its first input
    // (on a UA Apollo, outputs 1-2 come back on inputs 3-4, "MON L/R"), and the other inputs
    // carry live signal, so leak checks there count tone windows rather than non-zero frames.
    let d = device(opt("device") ?? "")
    let hz = Double(opt("hz") ?? "18500")!, secs = Double(opt("secs") ?? "3")!
    let want = max(Int(opt("channel") ?? "1") ?? 1, 1) - 1
    let rate = scalar(d, kAudioDevicePropertyNominalSampleRate, Float64(48000))
    let coeff = 2 * cos(2 * Double.pi * hz / rate), win = Int(rate / 10)
    let n = max(channels(d, input: true), 1)
    var s1 = [Double](repeating: 0, count: n), s2 = s1, best = [Double](repeating: -200, count: n)
    var k = 0, toneWindows = 0, nonzero = 0, firstNonzero = 0.0
    let lock = NSLock()
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, input, inTime, _, _ in
        let t = Double(inTime.pointee.mHostTime) * { var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return Double(tb.numer) / Double(tb.denom) / 1e9 }()
        lock.lock(); defer { lock.unlock() }
        var chans: [(UnsafeMutablePointer<Float>, Int, Int)] = []   // (buffer, stride, offset) per device channel
        var frames = 0
        for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(Int(b.mNumberChannels), 1); frames = Int(b.mDataByteSize) / 4 / ch
            for c in 0..<ch where chans.count < n { chans.append((p, ch, c)) }
        }
        for i in 0..<frames {
            for (c, (p, stride, offset)) in chans.enumerated() {
                let x = Double(p[i * stride + offset])
                if c == want, x != 0 { nonzero += 1; if firstNonzero == 0 { firstNonzero = t + Double(i) / rate } }
                let s = x + coeff * s1[c] - s2[c]; s2[c] = s1[c]; s1[c] = s
            }
            k += 1
            if k == win {
                for c in 0..<chans.count {
                    let pw = s1[c] * s1[c] + s2[c] * s2[c] - coeff * s1[c] * s2[c]
                    let a = 2 * max(pw, 0).squareRoot() / Double(win)
                    let level = a > 0 ? 20 * log10(a) : -200
                    best[c] = max(best[c], level)
                    if c == want, level > -100 { toneWindows += 1 }
                    s1[c] = 0; s2[c] = 0
                }
                k = 0
            }
        }
    }
    AudioDeviceStart(d, proc)
    let listenStart = audioClock()
    FileHandle.standardError.write("LISTENING\n".data(using: .utf8)!)
    usleep(UInt32(secs * 1_000_000))
    let listenEnd = audioClock()
    AudioDeviceStop(d, proc); AudioDeviceDestroyIOProcID(d, proc!)
    lock.lock()
    emit(["nonzeroFrames": nonzero, "toneDb": (best[min(want, n - 1)] * 10).rounded() / 10, "toneWindows": toneWindows,
          "firstNonzero": firstNonzero, "start": listenStart, "end": listenEnd, "channel": want + 1, "channelToneDb": best.map { ($0 * 10).rounded() / 10 }])
    lock.unlock()
case "capture":
    let hz = Double(opt("hz") ?? "18500")!, secs = Double(opt("secs") ?? "3")!
    guard secs > 0, secs <= 10 else { fail("--secs must be 0-10") }
    var wantSCK = argv.contains("--sck")
    var sckError: String?
    if wantSCK && !CGPreflightScreenCaptureAccess() {
        sckError = "not run: Screen Recording isn't granted to this host (never asked for)"
        wantSCK = false
    }
    // A Goertzel detector at the probe frequency per 100 ms window over the mean of channels 1-2:
    // `toneWindows` counts windows above -100 dBFS (the probe reads -60, or about -75 on a
    // 10-channel device's stereo mixdown; the user's own audio has nothing there).
    final class Detector {
        let hz: Double, lock = NSLock()
        var rate = 0.0, coeff = 0.0, win = 0, k = 0, s1 = 0.0, s2 = 0.0
        var best = -200.0, toneWindows = 0, frames = 0, nonzero = 0
        init(hz: Double) { self.hz = hz }
        func feed(_ abl: UnsafeMutableAudioBufferListPointer, rate r: Double) {
            lock.lock(); defer { lock.unlock() }
            if r != rate { rate = r; coeff = 2 * cos(2 * Double.pi * hz / r); win = Int(r / 10); k = 0; s1 = 0; s2 = 0 }
            var chans: [(UnsafeMutablePointer<Float>, Int, Int)] = []
            var n = 0
            for b in abl {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = max(Int(b.mNumberChannels), 1); n = Int(b.mDataByteSize) / 4 / ch
                for c in 0..<ch where chans.count < 2 { chans.append((p, ch, c)) }
            }
            guard !chans.isEmpty else { return }
            for i in 0..<n {
                var x = 0.0
                for (p, stride, offset) in chans { x += Double(p[i * stride + offset]) }
                x /= Double(chans.count)
                if x != 0 { nonzero += 1 }
                let s = x + coeff * s1 - s2; s2 = s1; s1 = s
                k += 1
                if k == win {
                    let pw = s1 * s1 + s2 * s2 - coeff * s1 * s2
                    let a = 2 * max(pw, 0).squareRoot() / Double(win)
                    let level = a > 0 ? 20 * log10(a) : -200
                    best = max(best, level)
                    if level > -100 { toneWindows += 1 }
                    s1 = 0; s2 = 0; k = 0
                }
            }
            frames += n
        }
        var json: [String: Any] { lock.lock(); defer { lock.unlock() }
            return ["toneWindows": toneWindows, "toneDb": (best * 10).rounded() / 10, "frames": frames, "nonzeroFrames": nonzero] }
    }
    // The global tap: unmuted, private, in a private tap-only aggregate. Destroyed before exit.
    let tapDetector = Detector(hz: hz)
    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    desc.muteBehavior = .unmuted
    desc.isPrivate = true
    desc.name = "audioprobe-capture"
    var tap = AudioObjectID(0)
    guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { fail("couldn't create the global tap") }
    let aggDict: [String: Any] = [
        kAudioAggregateDeviceNameKey: "audioprobe-capture", kAudioAggregateDeviceUIDKey: "audioprobe.capture.\(desc.uuid.uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: false,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
    ]
    var agg = AudioObjectID(0)
    guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg) == noErr else { AudioHardwareDestroyProcessTap(tap); fail("couldn't create the aggregate") }
    var fmtAddr = addr(kAudioTapPropertyFormat)
    var asbd = AudioStreamBasicDescription(); var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &asbdSize, &asbd)
    let tapRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
    var tapProc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&tapProc, agg, nil) { _, input, _, _, _ in
        tapDetector.feed(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), rate: tapRate)
    }
    AudioDeviceStart(agg, tapProc)
    func destroyTap() {
        AudioDeviceStop(agg, tapProc); AudioDeviceDestroyIOProcID(agg, tapProc!)
        AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
    }
    // Our own SCStream: main display, nothing excluded, audio on. excludesCurrentProcessAudio
    // must be off: on, SCK also drops other processes under the same responsible host (the
    // app under test can be one; docs/AUDIO_PLAN.md, capture spike).
    final class Out: NSObject, SCStreamOutput, SCStreamDelegate {
        let detector: Detector; var buffers = 0
        init(_ d: Detector) { detector = d }
        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            buffers += 1
            let rate = CMSampleBufferGetFormatDescription(sb).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48000
            try? sb.withAudioBufferList { abl, _ in detector.feed(abl, rate: rate) }
        }
    }
    let sckDetector = Detector(hz: hz)
    let out = Out(sckDetector)
    var stream: SCStream?
    if wantSCK {
        let sem = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, _ in content = c; sem.signal() }
        if sem.wait(timeout: .now() + 5) == .timedOut { sckError = "shareable content timed out" }
        else if let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content?.displays.first {
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = false
            cfg.sampleRate = 48000; cfg.channelCount = 2
            cfg.width = 64; cfg.height = 36
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.queueDepth = 3
            cfg.showsCursor = false
            let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: cfg, delegate: out)
            do {
                try s.addStreamOutput(out, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck-audio"))
                var startError: Error?
                s.startCapture { e in startError = e; sem.signal() }
                if sem.wait(timeout: .now() + 5) == .timedOut { sckError = "start timed out" }
                else if let startError { sckError = "start failed: \(startError.localizedDescription)" }
                else { stream = s }
            } catch { sckError = "addStreamOutput failed: \(error.localizedDescription)" }
        } else { sckError = "no display" }
    }
    if let ready = opt("ready") { FileManager.default.createFile(atPath: ready, contents: nil) }
    let start = audioClock()
    usleep(UInt32(secs * 1_000_000))
    let end = audioClock()
    if let s = stream {
        let sem = DispatchSemaphore(value: 0)
        s.stopCapture { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
    }
    destroyTap()
    var result: [String: Any] = ["hz": hz, "start": start, "end": end, "tap": tapDetector.json]
    if argv.contains("--sck") {
        var sck = sckDetector.json
        sck["buffers"] = out.buffers
        if let sckError { sck["error"] = sckError }
        result["sck"] = sck
    }
    emit(result)
default:
    fail("usage: audioprobe devices|mic|now|play|listen|capture")
}
