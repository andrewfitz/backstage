// Test helper for tests/audio.sh: measures a WAV independently of backstage (none of its code).
// Decodes through AVAudioFile (so Apple's parser validates the file), finds the bursts above a
// threshold, and reports each one's length, peak and RMS (dBFS) and its frequency, from a
// Hann-windowed Goertzel scan of the whole band (5 Hz steps, then 0.1 Hz around the best).
//   wavcheck <file.wav> [--threshold-db D]   (default -80)
import Foundation
import AVFoundation

let argv = Array(CommandLine.arguments.dropFirst())
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
guard let path = argv.first else { fail("usage: wavcheck <file.wav> [--threshold-db D]") }
let thresholdDb = argv.firstIndex(of: "--threshold-db").flatMap { $0 + 1 < argv.count ? Double(argv[$0 + 1]) : nil } ?? -80

let file: AVAudioFile
do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false) }
catch { fail("can't open \(path): \(error)") }
let format = file.processingFormat
let rate = format.sampleRate
let channels = Int(format.channelCount)
guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { fail("no buffer") }
do { try file.read(into: buffer) } catch { fail("can't read \(path): \(error)") }
let frames = Int(buffer.frameLength)
let data = (0..<channels).map { c in Array(UnsafeBufferPointer(start: buffer.floatChannelData![c], count: frames)) }
func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -200 }

// Bursts: stretches where some channel's |sample| reaches the threshold, joined across gaps
// shorter than 20 ms (a sine passes zero twice per cycle).
let threshold = Float(pow(10, thresholdDb / 20))
var bursts: [(start: Int, end: Int)] = []
var lastLoud = -1_000_000
for i in 0..<frames where data.contains(where: { abs($0[i]) >= threshold }) {
    if let b = bursts.last, i - lastLoud < Int(0.02 * rate) { bursts[bursts.count - 1] = (b.start, i + 1) }
    else { bursts.append((i, i + 1)) }
    lastLoud = i
}

func goertzelPower(_ x: [Double], _ hz: Double) -> Double {
    let w = 2 * Double.pi * hz / rate, coeff = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for v in x { let s0 = v + coeff * s1 - s2; s2 = s1; s1 = s0 }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2
}

func strongest(_ start: Int, _ end: Int) -> Double? {
    let n = end - start
    guard n >= 1024 else { return nil }
    let x = (0..<n).map { i -> Double in
        let mono = data.reduce(0.0) { $0 + Double($1[start + i]) } / Double(channels)
        return mono * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
    }
    var best = 0.0, bestPower = -1.0
    for hz in stride(from: 20.0, to: rate / 2, by: 5) {
        let p = goertzelPower(x, hz)
        if p > bestPower { bestPower = p; best = hz }
    }
    for hz in stride(from: best - 5, through: best + 5, by: 0.1) {
        let p = goertzelPower(x, hz)
        if p > bestPower { bestPower = p; best = hz }
    }
    return best
}

var out: [[String: Any]] = []
for b in bursts {
    var peak: Float = 0
    for c in data { for i in b.start..<b.end { peak = max(peak, abs(c[i])) } }
    // RMS and frequency over the steady middle: 20 ms in from each edge (past the ramps).
    let edge = Int(0.02 * rate)
    let (ms, me) = b.end - b.start > 4 * edge ? (b.start + edge, b.end - edge) : (b.start, b.end)
    var sum = 0.0
    for c in data { for i in ms..<me { sum += Double(c[i]) * Double(c[i]) } }
    var burst: [String: Any] = [
        "start": Double(b.start) / rate, "seconds": Double(b.end - b.start) / rate,
        "peakDb": (db(Double(peak)) * 100).rounded() / 100,
        "rmsDb": (db((sum / Double((me - ms) * channels)).squareRoot()) * 100).rounded() / 100,
    ]
    if let hz = strongest(ms, me) { burst["hz"] = (hz * 10).rounded() / 10 }
    out.append(burst)
}
let result: [String: Any] = [
    "sampleRate": rate, "channels": channels, "frames": frames, "seconds": Double(frames) / rate,
    "fileFormat": file.fileFormat.commonFormat == .pcmFormatFloat32 ? "float32" : "\(file.fileFormat.commonFormat.rawValue)",
    "thresholdDb": thresholdDb, "bursts": out,
    "toneSeconds": out.reduce(0.0) { $0 + ($1["seconds"] as! Double) },
]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
