import Foundation
import AppKit

/// The menu bar meter: while any managed app is making sound, the status item's icon is
/// replaced by five rounded bars drawn in the icon's own box, so the item never changes width.
/// The bars are the last five peak readings of the loudest playing app, newest on the right, on a
/// -60...0 dBFS scale. A 12 fps timer runs only while the meter shows; otherwise a 10 Hz poll
/// (only while the item is visible) watches for sound. 1 s after the sound stops the icon fades
/// back. With Reduce Motion, a static `waveform` symbol shows instead and nothing animates.
final class AudioMeter {
    static let barCount = 5
    static let floorDb: Float = -60
    static let frameInterval = 1.0 / 12
    static let pollInterval = 0.1
    static let holdAfterSilence = 1.0
    static let fadeDuration = 0.35

    private weak var button: NSStatusBarButton?
    /// The idle icon; its size is the box every meter image is drawn in.
    private let icon: NSImage
    private let source: () -> AudioLevelSource?
    private let log: (String) -> Void
    /// Called when `playingApp` changes (for the accessibility label and tooltip).
    var onChange: (() -> Void)?

    /// The loudest playing app's name while the meter shows sound; nil otherwise.
    private(set) var playingApp: String?
    private var showing = false
    private var readings = [Float](repeating: -.infinity, count: AudioMeter.barCount)
    private var lastDrawn: [Float]?
    private var silentSince: Double?
    private var fadeStart: Double?
    private var timer: Timer?
    private var timerInterval = 0.0
    private var active = false
    private(set) var reduceMotion: Bool
    private let reduceMotionOverride: Bool?
    private var observer: NSObjectProtocol?

    init(button: NSStatusBarButton, icon: NSImage, source: @escaping () -> AudioLevelSource?, log: @escaping (String) -> Void) {
        self.button = button
        self.icon = icon
        self.source = source
        self.log = log
        // Test-only: BACKSTAGE_REDUCE_MOTION=1/0 forces the mode instead of the system setting.
        switch ProcessInfo.processInfo.environment["BACKSTAGE_REDUCE_MOTION"] {
        case "1": reduceMotionOverride = true
        case "0": reduceMotionOverride = false
        default: reduceMotionOverride = nil
        }
        reduceMotion = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reduceMotionChanged() }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        timer?.invalidate()
    }

    /// The item is shown (apps are running) or hidden. Hidden: no timers, icon restored.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { schedule(Self.pollInterval) } else { stopShowing(); setTimer(nil) }
    }

    /// The current per-app levels, or nil when there's no audio source.
    func samples() -> [AudioLevelSample]? { source()?.currentLevels() }

    private func reduceMotionChanged() {
        let now = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard now != reduceMotion else { return }
        reduceMotion = now
        log("audio meter: reduce motion \(now ? "on" : "off")")
        guard showing else { return }
        fadeStart = nil
        lastDrawn = nil
        draw()
        schedule(reduceMotion ? Self.pollInterval : Self.frameInterval)
    }

    // MARK: state

    private func step() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let loudest = (samples() ?? []).filter { $0.playing }.max { $0.peakDb < $1.peakDb }
        if let loudest {
            silentSince = nil
            fadeStart = nil
            if !showing {
                showing = true
                log(String(format: "audio meter on: %@ at %.3f", loudest.name, Date().timeIntervalSince1970))
                schedule(reduceMotion ? Self.pollInterval : Self.frameInterval)
            }
            if playingApp != loudest.name { playingApp = loudest.name; onChange?() }
        } else if showing, fadeStart == nil {
            let since = silentSince ?? now
            silentSince = since
            if now - since >= Self.holdAfterSilence {
                if playingApp != nil {
                    log(String(format: "audio meter off at %.3f", Date().timeIntervalSince1970))
                    playingApp = nil
                    onChange?()
                }
                if reduceMotion { stopShowing(); schedule(Self.pollInterval); return }
                fadeStart = now
            }
        }
        guard showing else { return }
        if !reduceMotion, fadeStart == nil {
            readings.removeFirst()
            readings.append(loudest?.peakDb ?? -.infinity)
        }
        if let start = fadeStart, now - start >= Self.fadeDuration {
            stopShowing()
            schedule(Self.pollInterval)
            return
        }
        draw(now: now)
    }

    private func stopShowing() {
        let was = showing
        showing = false
        silentSince = nil
        fadeStart = nil
        lastDrawn = nil
        readings = [Float](repeating: -.infinity, count: Self.barCount)
        if was { button?.image = icon }
        if playingApp != nil { playingApp = nil; onChange?() }
    }

    private func draw(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard let button else { return }
        if reduceMotion {
            if lastDrawn == nil { button.image = Self.waveformImage(box: icon.size); lastDrawn = [] }
            return
        }
        let fade = fadeStart.map { CGFloat(min(1, (now - $0) / Self.fadeDuration)) } ?? 0
        let key = readings.map { Self.fraction($0) } + [Float(fade)]
        if key == lastDrawn { return }   // nothing moved: skip the redraw
        lastDrawn = key
        button.image = Self.barsImage(readings, box: icon.size, fade: fade, icon: icon)
    }

    // MARK: timers

    private func schedule(_ interval: Double) {
        if timer != nil, timerInterval == interval { return }
        setTimer(interval)
    }

    private func setTimer(_ interval: Double?) {
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)   // keeps running while a menu is open
        timer = t
        timerInterval = interval
    }

    // MARK: drawing (template images, so they follow light, dark and tinted menu bars)

    static func fraction(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return max(0, min(1, (db - floorDb) / -floorDb))
    }

    /// Five rounded bars centred in `box`; `fade` (0...1) crossfades to `icon`.
    static func barsImage(_ levels: [Float], box: NSSize, fade: CGFloat, icon: NSImage) -> NSImage {
        let fractions = levels.map { CGFloat(fraction($0)) }
        let img = NSImage(size: box, flipped: false) { rect in
            let usable = min(rect.width, rect.height * 1.2)
            let barW = usable / 8.2            // 5 bars and 4 gaps of 0.8 bar
            let gap = barW * 0.8
            let maxH = rect.height * 0.8
            var x = rect.midX - usable / 2
            NSColor.black.withAlphaComponent(1 - fade).setFill()
            for f in fractions {
                let h = barW + f * (maxH - barW)
                let bar = NSRect(x: x, y: rect.midY - h / 2, width: barW, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            if fade > 0 { icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fade) }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// The static Reduce Motion symbol, fitted into the icon's box.
    static func waveformImage(box: NSSize) -> NSImage {
        symbolImage("waveform", box: box) ?? NSImage(size: box)
    }

    /// An SF Symbol drawn into a plain template image of `box` size (its own size if nil). The
    /// status item uses only such images, idle icon included: the button lays out a symbol image
    /// differently from a drawn one (half a point wider), so mixing them would move the item.
    static func symbolImage(_ name: String, box: NSSize? = nil, description: String? = nil) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let box = box ?? symbol.size
        let img = NSImage(size: box, flipped: false) { rect in
            guard symbol.size.width > 0, symbol.size.height > 0 else { return true }
            let s = min(rect.width / symbol.size.width, rect.height / symbol.size.height, 1)
            let size = NSSize(width: symbol.size.width * s, height: symbol.size.height * s)
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = description
        return img
    }
}

/// TEST ONLY: a synthetic audio source, so the meter can be developed and checked without real
/// sound (it makes none). Enabled only by `BACKSTAGE_FAKE_AUDIO` in the daemon's environment:
/// - `any`: the first running managed app plays a synthetic level pattern, 3 s on, 3 s off.
/// - `<pid>`: the same, for that managed app only.
/// - `/path/to/file`: the first managed app plays while that file exists (for latency checks).
/// When set, it takes precedence over the real source.
final class FakeAudioSource: AudioLevelSource {
    enum Mode { case pattern(pid_t?), file(String) }
    let mode: Mode
    private weak var daemon: Daemon?
    private let start = ProcessInfo.processInfo.systemUptime

    init?(daemon: Daemon, spec: String?) {
        guard let spec, !spec.isEmpty else { return nil }
        if spec.hasPrefix("/") { mode = .file(spec) }
        else if spec == "any" { mode = .pattern(nil) }
        else if let pid = pid_t(spec) { mode = .pattern(pid) }
        else { return nil }
        self.daemon = daemon
    }

    func currentLevels() -> [AudioLevelSample] {
        guard let d = daemon else { return [] }
        let apps = d.registry.filter { d.managed.contains($0.pid) }.sorted { $0.launchedAt < $1.launchedAt }
        let t = ProcessInfo.processInfo.systemUptime - start
        let sounding: pid_t?
        switch mode {
        case .pattern(let pid):
            let on = t.truncatingRemainder(dividingBy: 6) < 3
            sounding = on ? (pid ?? apps.first?.pid) : nil
        case .file(let path):
            sounding = access(path, F_OK) == 0 ? apps.first?.pid : nil
        }
        // A wobbling level between about -54 and -3 dBFS, so the bars move like real audio.
        let wobble = sin(t * 7.3) * 0.5 + sin(t * 2.1) * 0.35 + sin(t * 17.9) * 0.15
        let peak = Float(-28 + 25 * wobble)
        return apps.map { a in
            let on = a.pid == sounding
            return AudioLevelSample(pid: a.pid, name: a.name, playing: on,
                                    peakDb: on ? peak : -.infinity, rmsDb: on ? peak - 3 : -.infinity)
        }
    }
}
