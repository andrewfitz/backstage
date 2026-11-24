import Foundation
import AppKit
import QuartzCore

/// The menu bar meter: while any managed app is making sound, the status item's icon is
/// replaced by five rounded bars in the icon's own box, so the item never changes width. The
/// bars are the last five peak readings of the loudest playing app, newest on the right, on a
/// -60...0 dBFS scale. A 12 fps timer runs only while the meter shows; otherwise a 20 Hz poll
/// (only while the item is visible) watches for sound. 1 s after the sound stops the icon fades
/// back. With Reduce Motion, a static `waveform` symbol shows instead and nothing animates.
///
/// Cost: changing the button's image makes AppKit redraw it and re-snapshot it for the status
/// item's copy on every other display's menu bar (agent displays included), about 6% CPU at
/// 12 fps. So the bars are Core Animation layers in a layer-hosting view over a blank image of
/// the icon's size: a frame only moves five layers, and nothing is redrawn or re-snapshotted.
/// The copies on other displays are refreshed once a second instead.
final class AudioMeter {
    static let barCount = 5
    static let floorDb: Float = -60
    static let frameInterval = 1.0 / 12
    static let pollInterval = 0.05
    static let holdAfterSilence = 1.0
    static let fadeDuration = 0.35
    static let copyRefreshInterval = 1.0

    private weak var button: NSStatusBarButton?
    /// The idle icon; its size is the box the meter occupies.
    private let icon: NSImage
    /// Holds the icon's place in the button (same size, so the same width) while bars show.
    private let blank: NSImage
    private let source: () -> AudioLevelSource?
    private let log: (String) -> Void
    /// Called when `playingApp` changes (for the accessibility label and tooltip).
    var onChange: (() -> Void)?

    /// The loudest playing app's name while the meter shows sound; nil otherwise.
    private(set) var playingApp: String?
    private enum Phase { case idle, showing, fading }
    private var phase = Phase.idle
    private var readings = [Float](repeating: -.infinity, count: AudioMeter.barCount)
    private var lastFractions: [CGFloat]?
    private var silentSince: Double?
    private var fadeToken = 0
    private var nextCopyRefresh = 0.0
    private var timer: Timer?
    private var timerInterval = 0.0
    private var active = false
    private(set) var reduceMotion: Bool
    private let reduceMotionOverride: Bool?
    private var observer: NSObjectProtocol?
    private var barsView: NSView?
    private var bars: [CALayer] = []

    init(button: NSStatusBarButton, icon: NSImage, source: @escaping () -> AudioLevelSource?, log: @escaping (String) -> Void) {
        self.button = button
        self.icon = icon
        self.source = source
        self.log = log
        let blank = NSImage(size: icon.size, flipped: false) { _ in true }
        blank.isTemplate = true
        self.blank = blank
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
        if on { schedule(Self.pollInterval) } else { hide(); setTimer(nil) }
    }

    /// The current per-app levels, or nil when there's no audio source.
    func samples() -> [AudioLevelSample]? { source()?.currentLevels() }

    private func reduceMotionChanged() {
        let now = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard now != reduceMotion else { return }
        reduceMotion = now
        log("audio meter: reduce motion \(now ? "on" : "off")")
        switch phase {
        case .showing: show()
        case .fading: hide()
        case .idle: break
        }
        if active { schedule(phase == .showing && !reduceMotion ? Self.frameInterval : Self.pollInterval) }
    }

    // MARK: state

    private func step() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let loudest = (samples() ?? []).filter { $0.playing }.max { $0.peakDb < $1.peakDb }
        if let loudest {
            silentSince = nil
            if phase == .idle { log(String(format: "audio meter on: %@ at %.3f", loudest.name, Date().timeIntervalSince1970)) }
            if phase != .showing { show() }
            if playingApp != loudest.name { playingApp = loudest.name; onChange?() }
        } else if phase == .showing {
            let since = silentSince ?? now
            silentSince = since
            if now - since >= Self.holdAfterSilence {
                log(String(format: "audio meter off at %.3f", Date().timeIntervalSince1970))
                silentSince = nil
                if playingApp != nil { playingApp = nil; onChange?() }
                if reduceMotion { hide() } else { fade() }
            }
        }
        if phase == .showing, !reduceMotion {
            readings.removeFirst()
            readings.append(loudest?.peakDb ?? -.infinity)
            updateBars()
            // Refresh the copies on other displays' menu bars once a second.
            if now >= nextCopyRefresh, let button {
                nextCopyRefresh = now + Self.copyRefreshInterval
                button.needsDisplay = true
            }
        }
        schedule(phase == .showing && !reduceMotion ? Self.frameInterval : Self.pollInterval)
    }

    /// Bars (or the Reduce Motion symbol) in place of the icon. Also cancels a fade.
    private func show() {
        guard let button else { return }
        fadeToken += 1
        phase = .showing
        button.layer?.removeAnimation(forKey: "meterFade")
        if reduceMotion {
            removeBars()
            button.image = Self.waveformImage(box: icon.size)
            return
        }
        let view = barsView ?? makeBars(in: button)
        view.frame = iconRect(in: button)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.removeAllAnimations()
        view.layer?.opacity = 1
        CATransaction.commit()
        if button.image !== blank { button.image = blank }
        lastFractions = nil
        updateBars()
    }

    /// The icon fades back in while the bars fade out, both run by the render server.
    private func fade() {
        guard let button, let layer = barsView?.layer else { hide(); return }
        phase = .fading
        fadeToken += 1
        let token = fadeToken
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = Self.fadeDuration
        layer.opacity = 0
        layer.add(out, forKey: "fade")
        let crossfade = CATransition()
        crossfade.type = .fade
        crossfade.duration = Self.fadeDuration
        button.layer?.add(crossfade, forKey: "meterFade")
        CATransaction.commit()
        button.image = icon
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { [weak self] in
            guard let self, self.fadeToken == token else { return }
            self.hide()
        }
    }

    /// Back to the plain icon at once.
    private func hide() {
        fadeToken += 1
        phase = .idle
        silentSince = nil
        readings = [Float](repeating: -.infinity, count: Self.barCount)
        lastFractions = nil
        removeBars()
        if let button, button.image !== icon { button.image = icon }
        if playingApp != nil { playingApp = nil; onChange?() }
    }

    // MARK: bars

    /// A layer-hosting view: AppKit never draws it, so moving its layers redraws nothing.
    private final class BarsView: NSView {
        var appearanceChanged: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the button
        // The menu bar switches between light and dark with the wallpaper: recolour the bars.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            appearanceChanged?()
        }
    }

    private func makeBars(in button: NSStatusBarButton) -> NSView {
        let view = BarsView(frame: iconRect(in: button))
        view.appearanceChanged = { [weak self] in self?.updateColors() }
        let root = CALayer()
        view.layer = root
        view.wantsLayer = true
        bars = (0..<Self.barCount).map { _ in
            let bar = CALayer()
            root.addSublayer(bar)
            return bar
        }
        button.addSubview(view)
        barsView = view
        updateColors()
        return view
    }

    private func removeBars() {
        barsView?.removeFromSuperview()
        barsView = nil
        bars = []
    }

    /// Where the button draws its image.
    private func iconRect(in button: NSStatusBarButton) -> NSRect {
        let size = icon.size
        if let r = button.cell?.imageRect(forBounds: button.bounds), r.width > 0, r.height > 0 {
            return NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
        }
        return NSRect(x: 0, y: (button.bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Template images in the menu bar are drawn in its label colour; match it.
    private func updateColors() {
        guard let button, !bars.isEmpty else { return }
        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color }
        CATransaction.commit()
    }

    private func updateBars() {
        guard let view = barsView, bars.count == readings.count else { return }
        let fractions = readings.map { CGFloat(Self.fraction($0)) }
        if fractions == lastFractions { return }   // nothing moved (silence): no commit
        lastFractions = fractions
        let scale = view.window?.backingScaleFactor ?? 2
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let rect = view.bounds
        let usable = min(rect.width, rect.height * 1.2)
        let barW = px(usable / 8.2)            // 5 bars and 4 gaps of 0.8 bar
        let gap = px(barW * 0.8)
        let total = barW * 5 + gap * 4
        let maxH = rect.height * 0.8
        var x = px(rect.midX - total / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, f) in zip(bars, fractions) {
            let h = px(barW + f * (maxH - barW))
            bar.frame = CGRect(x: x, y: px(rect.midY - h / 2), width: barW, height: h)
            bar.cornerRadius = barW / 2
            x += barW + gap
        }
        CATransaction.commit()
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

    // MARK: images

    static func fraction(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return max(0, min(1, (db - floorDb) / -floorDb))
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
