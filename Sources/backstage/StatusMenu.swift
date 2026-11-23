import Foundation
import AppKit
import ScreenCaptureKit

/// Menu bar indicator owned by the daemon. Visible only while agents have apps running;
/// the menu shows live thumbnails of the agent display(s) and basic stats.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private weak var daemon: Daemon?
    private var thumbViews: [CGDirectDisplayID: NSImageView] = [:]
    private var refreshTimer: Timer?
    private var capturing = false
    private var thumbLock: StateLock?
    static let thumbWidth: CGFloat = 320
    /// The agent display has its own copy of the menu bar; leave it out of the thumbnail.
    static func menuBarHeight(_ id: CGDirectDisplayID) -> CGFloat {
        guard let screen = nsScreen(id) else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    init(daemon: Daemon) {
        self.daemon = daemon
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.isVisible = false
        if let button = item.button {
            let img = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Backstage")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.toolTip = "Backstage: agents are using apps on a hidden display"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    /// Called from the daemon tick (cheap): show/hide and update the count in the menu bar.
    func update(apps: Int) {
        let visible = apps > 0
        if item.isVisible != visible { item.isVisible = visible }
        if visible { item.button?.title = " \(apps)" }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        refreshThumbnails()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshThumbnails()
            self?.refreshStatsLine()
        }
        RunLoop.main.add(t, forMode: .common)   // keeps firing while the menu is tracking
        refreshTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private var statsItem: NSMenuItem?

    private func rebuild() {
        menu.removeAllItems()
        thumbViews.removeAll()
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

        for id in activeDisplays().filter(isOurDisplay) {
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
        }
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
        let ours = activeDisplays().filter(isOurDisplay).map { CGDisplayBounds($0) }
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
        thumbLock = lock
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { lock.release() }
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
