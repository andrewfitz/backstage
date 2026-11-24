import Foundation
import AppKit
import ScreenCaptureKit

/// Menu bar indicator owned by the daemon. Visible only while agents have apps running;
/// the menu shows a live thumbnail of this daemon's agent display and basic stats.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private weak var daemon: Daemon?
    private var thumbViews: [CGDirectDisplayID: NSImageView] = [:]
    private var refreshTimer: Timer?
    private var capturing = false
    private var thumbLock: StateLock?
    private var thumbUserLock: UserLock?
    static let thumbWidth: CGFloat = 320
    /// The agent display has its own copy of the menu bar; leave it out of the thumbnail.
    static func menuBarHeight(_ id: CGDirectDisplayID) -> CGFloat {
        guard let screen = nsScreen(id) else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    static let defaultToolTip = "Backstage: agents are using apps on a hidden display"
    private var meter: AudioMeter?
    /// TEST ONLY (BACKSTAGE_FAKE_AUDIO): a synthetic level source that wins over the real one.
    private var fakeAudio: AudioLevelSource?
    private var appCount = 0

    init(daemon: Daemon) {
        self.daemon = daemon
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.isVisible = false
        fakeAudio = FakeAudioSource(daemon: daemon, spec: ProcessInfo.processInfo.environment["BACKSTAGE_FAKE_AUDIO"])
        if fakeAudio != nil { daemon.log("audio meter: using the test-only fake audio source (BACKSTAGE_FAKE_AUDIO)") }
        if let button = item.button {
            // Drawn into a plain image, like every meter frame, so the item's width never changes.
            let img = AudioMeter.symbolImage("rectangle.on.rectangle", description: "Backstage")
            button.image = img
            button.imagePosition = .imageLeading
            button.toolTip = Self.defaultToolTip
            if let img {
                // Read the source on every poll: the tap manager may set it after we're created.
                meter = AudioMeter(button: button, icon: img, source: { [weak self] in self?.fakeAudio ?? self?.daemon?.audioLevels },
                                   log: { [weak daemon] in daemon?.log($0) })
                meter?.onChange = { [weak self] in self?.updateLabel() }
            }
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    /// Called from the daemon tick (cheap): show/hide and update the count in the menu bar.
    func update(apps: Int) {
        let visible = apps > 0
        if item.isVisible != visible { item.isVisible = visible }
        // Only on change: setting the title redraws the item and its copy on every other
        // display's menu bar, about 1% CPU at this rate even when the text is the same.
        let title = " \(apps)"
        if visible, item.button?.title != title { item.button?.title = title }
        meter?.setActive(visible)
        if apps != appCount { appCount = apps; updateLabel() }
    }

    /// VoiceOver label and tooltip; changed only when the app count or audio state changes.
    private func updateLabel() {
        guard let button = item.button else { return }
        var label = "Backstage, \(appCount) app\(appCount == 1 ? "" : "s")"
        var tip = Self.defaultToolTip
        if let name = meter?.playingApp {
            label += ", playing audio, muted"
            tip = "Backstage: \(name) is playing audio (muted, you can't hear it)"
        }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.toolTip != tip { button.toolTip = tip }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        refreshThumbnails()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshThumbnails()
            self?.refreshStatsLine()
            self?.refreshAudioLines()
        }
        RunLoop.main.add(t, forMode: .common)   // keeps firing while the menu is tracking
        refreshTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private var statsItem: NSMenuItem?

    /// Each app's menu line and its text without the audio part, for the 1 s refresh.
    private var appLines: [pid_t: (item: NSMenuItem, text: String)] = [:]

    private func rebuild() {
        menu.removeAllItems()
        thumbViews.removeAll()
        appLines.removeAll()
        guard let d = daemon else { return }
        let apps = d.registry.filter { $0.matchesProcess }

        let title = NSMenuItem(title: "Backstage: agents working off-screen", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let stats = NSMenuItem(title: statsText(), action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)
        statsItem = stats
        menu.addItem(.separator())

        // This daemon's display only: other homes' daemons show theirs in their own menus.
        for id in [d.display.id] where CGDisplayIsActive(id) != 0 {
            let b = CGDisplayBounds(id)
            let h = (Self.thumbWidth * (b.height - Self.menuBarHeight(id)) / max(b.width, 1)).rounded()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.thumbWidth + 28, height: h + 12))
            let iv = NSImageView(frame: NSRect(x: 14, y: 6, width: Self.thumbWidth, height: h))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6
            iv.layer?.masksToBounds = true
            iv.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            container.addSubview(iv)
            let mi = NSMenuItem()
            mi.view = container
            menu.addItem(mi)
            thumbViews[id] = iv
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: apps.isEmpty ? "No apps running" : "Apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for a in apps.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            let windows = axApp(a.pid).windows.count
            let who = a.agent ?? "manual"
            let mi = NSMenuItem(title: "\(a.name) · \(who) · \(windows) window\(windows == 1 ? "" : "s") · \(ago(a.launchedAt))", action: nil, keyEquivalent: "")
            if let url = NSRunningApplication(processIdentifier: a.pid)?.bundleURL {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                mi.image = icon
            }
            let sub = NSMenu()
            let show = NSMenuItem(title: "Show on My Screen", action: #selector(showApp(_:)), keyEquivalent: "")
            show.target = self; show.tag = Int(a.pid)
            let quit = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "")
            quit.target = self; quit.tag = Int(a.pid)
            let info = NSMenuItem(title: "pid \(a.pid) · \(a.bundleID ?? a.path)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(show); sub.addItem(quit); sub.addItem(.separator()); sub.addItem(info)
            mi.submenu = sub
            menu.addItem(mi)
            appLines[a.pid] = (mi, mi.title)
        }
        refreshAudioLines()
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Screenshots & Logs Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let stop = NSMenuItem(title: "Quit All Agent Apps", action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = !apps.isEmpty
        menu.addItem(stop)
    }

    private func statsText() -> String {
        guard let d = daemon else { return "" }
        let apps = d.registry.filter { $0.matchesProcess }
        let sessions = Set(apps.map { $0.owner }).count
        let ours = [d.display.bounds]
        let pids = Set(apps.map { $0.pid })
        let windows = onscreenWindows().filter {
            guard let pid = $0[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  ($0[kCGWindowLayer as String] as? Int) == 0 else { return false }
            let b = cgBounds($0)
            return ours.contains { $0.intersects(b) }
        }.count
        func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        return "\(plural(sessions, "session")) · \(plural(apps.count, "app")) · \(plural(windows, "window")) · up \(ago(d.startedAt, suffix: false))"
    }

    private func refreshStatsLine() { statsItem?.title = statsText() }

    /// Appends a speaker symbol and "playing" or "silent" to each measured app's line (launched
    /// with --audio; the others aren't measured, so their lines stay as they are). Without an
    /// audio source (no taps), every line stays as it is.
    private func refreshAudioLines() {
        guard !appLines.isEmpty, let samples = meter?.samples() else { return }
        let playing = Set(samples.filter { $0.playing }.map { $0.pid })
        let measured = Set(samples.map { $0.pid })
        let font = NSFont.menuFont(ofSize: 0)
        for (pid, line) in appLines {
            guard measured.contains(pid) else {
                if line.item.attributedTitle != nil { line.item.attributedTitle = nil; line.item.title = line.text }
                continue
            }
            let on = playing.contains(pid)
            let text = NSMutableAttributedString(string: line.text + " · ", attributes: [.font: font])
            let symbol = NSImage(systemSymbolName: on ? "speaker.wave.2.fill" : "speaker.fill",
                                 accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular))
            if let symbol {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                // Sit the symbol on the text's baseline like a glyph.
                attachment.bounds = NSRect(x: 0, y: font.descender / 2, width: symbol.size.width, height: symbol.size.height)
                text.append(NSAttributedString(attachment: attachment))
            }
            text.append(NSAttributedString(string: on ? " playing" : " silent", attributes: [.font: font]))
            if line.item.attributedTitle != text { line.item.attributedTitle = text }
        }
    }

    private func ago(_ t: Double, suffix: Bool = true) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970 - t))
        let text = s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \((s % 3600) / 60)m"
        return suffix ? text + " ago" : text
    }

    /// Small, cheap captures of each agent display while the menu is open.
    private func refreshThumbnails() {
        guard !capturing, !thumbViews.isEmpty else { return }
        // Concurrent ScreenCaptureKit calls hang (see `capture`), so share capture.lock with the
        // CLI. Never wait for it here: skip this refresh if a capture is running. A thumbnail
        // capture that doesn't return gives the lock back after 5 s, since the daemon can't exit
        // to clear it.
        guard let lock = try? StateLock("capture.lock", nonblocking: true) else { return }
        guard let userLock = UserLock("capture.lock", nonblocking: true) else { lock.release(); return }
        thumbLock = lock
        thumbUserLock = userLock
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { lock.release(); userLock.release() }
        capturing = true
        let targets = thumbViews.map { ($0.key, $0.value.frame.size, Self.menuBarHeight($0.key)) }
        Task.detached { [weak self] in
            var images: [CGDirectDisplayID: CGImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                for (id, size, menuBar) in targets {
                    guard let disp = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let cfg = SCStreamConfiguration()
                    let db = CGDisplayBounds(id)
                    cfg.sourceRect = CGRect(x: 0, y: menuBar, width: db.width, height: db.height - menuBar)
                    cfg.width = Int(size.width * 2); cfg.height = Int(size.height * 2)
                    cfg.showsCursor = false
                    if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: disp, excludingWindows: []), configuration: cfg) {
                        images[id] = img
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                self.thumbLock?.release(); self.thumbLock = nil
                self.thumbUserLock?.release(); self.thumbUserLock = nil
                for (id, img) in images { self.thumbViews[id]?.image = NSImage(cgImage: img, size: .zero) }
            }
        }
    }

    // MARK: actions (user-initiated)

    @objc private func showApp(_ sender: NSMenuItem) {
        guard let rec = daemon?.registry.first(where: { $0.pid == pid_t(sender.tag) }) else { NSSound.beep(); return }
        do { try handOver(rec, wait: false) } catch { NSSound.beep(); daemon?.log("menu show failed (busy launch/stop?): \(error)") }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let rec = daemon?.registry.first(where: { $0.pid == pid_t(sender.tag) }) else { return }
        do { try rec.requestTermination(force: false) } catch { daemon?.log("menu quit failed: \(error)") }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Paths.dir)
    }

    @objc private func stopAll() {
        daemon?.shutdown(reason: "stopped from the menu bar")
    }
}
