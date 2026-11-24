import Foundation
import AppKit
import QuartzCore
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Menu bar indicator owned by the daemon. Visible while apps are running backstage, or always
/// with Keep in Menu Bar on.
///
/// The menu answers, in this order: what is going on back there (a sentence and a live picture
/// of this daemon's agent display), who is doing it (apps grouped by agent session), and what
/// can I do about it (bring an app to my screen, quit it, quit everything). Process IDs and
/// bundle IDs stay in each app's submenu.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private weak var daemon: Daemon?
    private var refreshTimer: Timer?
    private var capturing = false
    private var thumbnailGeneration = 0
    /// The picture's width in points. A capture is never wider than twice this in pixels
    /// (`runMenuThumbnail` refuses more).
    static let thumbWidth: CGFloat = 320
    /// The agent display has its own copy of the menu bar; leave it out of the thumbnail.
    static func menuBarHeight(_ id: CGDirectDisplayID) -> CGFloat {
        guard let screen = nsScreen(id) else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private var meter: AudioMeter?
    /// TEST ONLY (BACKSTAGE_FAKE_AUDIO): a synthetic level source that wins over the real one.
    private var fakeAudio: AudioLevelSource?

    /// The sentence and the picture at the top. Kept between openings, so a reopened menu has
    /// the last picture (faded) at once instead of a placeholder.
    private var hero: MenuHeroView?
    private var heroItem: NSMenuItem?
    private var heroShape = ""
    /// Several displays: which page of pictures is showing (two per page), the display each
    /// picture shows, the last picture of each display (shown faded at once when paging to it),
    /// and the pictures still to capture this round (one capture at a time).
    private var page = 0
    private var visibleSlots: [Int] = []
    private var lastImages: [Int: CGImage] = [:]
    private var captureQueue: [(index: Int, slot: Int)] = []
    /// Each app's row, and what the rows were built from (to notice apps coming and going).
    private var rows: [pid_t: NSMenuItem] = [:]
    private var rowsKey: [String] = []
    private var openedAt = 0.0
    private var lastFrame = 0.0
    private var captureFailureLogged = false

    init(daemon: Daemon) {
        self.daemon = daemon
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.isVisible = false
        fakeAudio = FakeAudioSource(daemon: daemon, spec: ProcessInfo.processInfo.environment["BACKSTAGE_FAKE_AUDIO"])
        if fakeAudio != nil { daemon.log("audio meter: using the test-only fake audio source (BACKSTAGE_FAKE_AUDIO)") }
        if let button = item.button {
            // A display behind a display, the one behind dashed: the hidden one. Drawn into a
            // plain image, like every meter frame, so the icon's box never changes; the number of
            // running apps sits beside it (the width changes only when the count gains a digit).
            let img = AudioMeter.symbolImage("rectangle.on.rectangle.dashed", description: "Backstage")
                ?? AudioMeter.symbolImage("rectangle.on.rectangle", description: "Backstage")
            button.image = img
            button.imagePosition = .imageLeading
            if let img {
                // Read the source on every poll: the tap manager may set it after we're created.
                meter = AudioMeter(button: button, icon: img, source: { [weak self] in self?.fakeAudio ?? self?.daemon?.audioLevels },
                                   log: { [weak daemon] in daemon?.log($0) })
                meter?.onChange = { [weak self] in self?.updateLabel() }
            }
        }
        updateLabel()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = MenuHeroView.width(previewWidth: Self.thumbWidth)
        item.menu = menu
    }

    /// Called from the daemon tick (cheap): show/hide the item and keep its tooltip current.
    func update(apps: Int) {
        let visible = apps > 0 || daemon?.keepActive == true
        if item.isVisible != visible {
            item.isVisible = visible
            meter?.layoutChanged()
        }
        meter?.setActive(visible && (fakeAudio != nil || daemon?.registry.contains { $0.audioMode.metered } == true))
        if visible {
            // Set only on change: touching the button redraws every copy of the item. With no
            // apps (Keep in Menu Bar), the icon stands alone: no "0".
            let title = apps > 0 ? " \(apps)" : ""
            if let button = item.button, button.title != title { button.title = title; meter?.layoutChanged() }
            updateLabel()
        }
    }

    /// A note for the tooltip after Send Front Window Backstage, until it expires.
    private var cueNote: (text: String, until: Double)?

    /// Quiet feedback for Send Front Window Backstage: a VoiceOver announcement, a line in the
    /// tooltip, and a short animation of the icon (two soft blinks when sent, a small shake when
    /// refused; with Reduce Motion, one dim). No sound, no alert, nothing that takes focus.
    func sendCue(text: String, success: Bool) {
        cueNote = (text, ProcessInfo.processInfo.systemUptime + 6)
        updateLabel()
        guard let button = item.button else { return }
        NSAccessibility.post(element: button, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard item.isVisible, let layer = button.layer else { return }
        let reduce = meter?.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation: CAAnimation
        if reduce || success {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = reduce ? [1, 0.4, 1] : [1, 0.25, 1, 0.25, 1]
            blink.duration = reduce ? 0.5 : 0.7
            animation = blink
        } else {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -3, 3, -2, 2, 0]
            shake.duration = 0.35
            animation = shake
        }
        layer.add(animation, forKey: "sendCue")
    }

    /// VoiceOver label and tooltip. Set only when they change: touching the button redraws the
    /// item and its copy on every other display's menu bar.
    private func updateLabel() {
        guard let button = item.button else { return }
        let summary = Self.summary(daemon?.registry ?? [])
        var label = "Backstage, " + summary
        var tip = "Backstage: " + summary
        if let name = meter?.playingApp {
            label += ". \(name) is playing sound, muted"
            tip += "\n\(name) is playing sound (muted, you can't hear it)"
        }
        if let note = cueNote {
            if ProcessInfo.processInfo.systemUptime < note.until { tip += "\n" + note.text } else { cueNote = nil }
        }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.toolTip != tip { button.toolTip = tip }
    }

    // MARK: wording

    /// How agents are named to people. An app's `agent` is the launching process's name: one of
    /// these for a known agent, anything else (Terminal, python3…) otherwise.
    static let agentNames = ["claude": "Claude", "codex": "Codex", "grok": "Grok", "cursor-agent": "Cursor", "gemini": "Gemini",
                             "opencode": "OpenCode", "aider": "Aider", "amp": "Amp", "goose": "Goose"]

    /// One sentence for the top of the menu and the tooltip: who is using how many apps.
    static func summary(_ all: [ManagedApp]) -> String {
        guard !all.isEmpty else { return "No apps running" }
        // Apps the user sent here are theirs, not an agent's.
        let sent = all.filter { Session.isUser($0.session) }.count
        let apps = all.filter { !Session.isUser($0.session) }
        let sentPart = sent == 1 ? "1 app you sent" : "\(sent) apps you sent"
        if apps.isEmpty { return "\(sentPart) \(sent == 1 ? "is" : "are") on a hidden display" }
        let agentPart = agentSummary(apps)
        return sent == 0 ? agentPart : "\(agentPart), with \(sentPart)"
    }

    private static func agentSummary(_ apps: [ManagedApp]) -> String {
        let what = apps.count == 1 ? "1 app" : "\(apps.count) apps"
        var agents: [String] = []
        for app in apps.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            // Something other than a known agent launched one: don't credit the agents with all of them.
            guard let name = app.agent.flatMap({ agentNames[$0] }) else {
                return "\(what) \(apps.count == 1 ? "is" : "are") running on a hidden display"
            }
            if !agents.contains(name) { agents.append(name) }
        }
        switch agents.count {
        case 1: return "\(agents[0]) is using \(what) on a hidden display"
        case 2: return "\(agents[0]) and \(agents[1]) are using \(what) on a hidden display"
        default: return "\(agents.count) agents are using \(what) on a hidden display"
        }
    }

    /// The name a person gave a session with BACKSTAGE_SESSION; nil for the IDs backstage derives
    /// itself (`claude:<uuid>`, `tty:<sid>-<start>`, `<process>:<pid>-<start>`), which mean
    /// nothing to anyone.
    static func givenSessionName(_ owner: String) -> String? {
        if owner == Session.legacy || Session.isUser(owner) { return nil }
        guard let colon = owner.firstIndex(of: ":") else { return owner }
        let kind = String(owner[..<colon])
        if Session.knownAgents.contains(kind) || kind == "tty" || kind == "process" { return nil }
        let parts = owner[owner.index(after: colon)...].split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) { return nil }
        return owner
    }

    /// The folder the launching agent works in: how people tell their agent sessions apart.
    static func workingFolder(of app: ManagedApp) -> String? {
        // The agent's PID may have been reused since: it must be older than the app it launched.
        guard let pid = app.agentPID, let birth = processBirth(pid), Double(birth) / 1e6 <= app.launchedAt else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard !path.isEmpty, path != "/", path != NSHomeDirectory() else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Apps grouped by the session that launched them, oldest first, each under a heading such as
    /// "Claude — myproject": the agent, then the session's given name or the agent's folder.
    static func groups(_ apps: [ManagedApp], folder: (ManagedApp) -> String? = workingFolder) -> [(label: String, apps: [ManagedApp])] {
        // Owners are compared as bytes: two session names that only normalize alike are two sessions.
        var order: [Data] = []
        var members: [Data: [ManagedApp]] = [:]
        for app in apps.sorted(by: { ($0.launchedAt, $0.pid) < ($1.launchedAt, $1.pid) }) {
            let owner = Data(app.owner.utf8)
            if members[owner] == nil { order.append(owner) }
            members[owner, default: []].append(app)
        }
        var used: [String: Int] = [:]
        return order.map { key in
            let apps = members[key] ?? []
            let owner = apps.first?.owner ?? ""
            let agent = apps.lazy.compactMap { $0.agent }.first
            let who = agent.map { agentNames[$0] ?? $0 } ?? (owner.hasPrefix("tty:") ? "Terminal" : "Other")
            let detail = givenSessionName(owner) ?? apps.lazy.compactMap(folder).first
            var label = Session.isUser(owner) ? "Sent by you" : clipped(detail.map { "\(who) — \($0)" } ?? who, to: 40)
            used[label, default: 0] += 1
            if let n = used[label], n > 1 { label += " (\(n))" }
            return (label, apps)
        }
    }

    /// "Running for 12 min", plus only what's worth a second look: no windows, or sound. If
    /// that's too long for the menu's width, how long it has run is the part that goes.
    /// `sent`: the user sent it backstage (launchedAt is when), so its age is "Sent … ago".
    static func detail(launchedAt: Double, now: Double, windows: Int, playing: Bool, sent: Bool = false, display: Int? = nil) -> String {
        let minutes = max(0, Int(now - launchedAt)) / 60, hours = minutes / 60
        var age: String
        switch minutes {
        case ..<1: age = sent ? "Just sent" : "Just launched"
        case ..<60: age = "\(minutes) min"
        case ..<600: age = "\(hours) hr" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
        case ..<2880: age = "\(hours) hr"
        default: age = "\(hours / 24) days"
        }
        if minutes >= 1 { age = sent ? "Sent \(age) ago" : "Running for \(age)" }
        var parts = [age]
        if windows == 0 { parts.append("No windows") }
        if playing { parts.append("Playing sound (muted)") }
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: [.font: font]).width <= detailWidth }
        if parts.count > 1, !fits(parts.joined(separator: " · ")) { parts.removeFirst() }
        // With several displays, which one leads (it's what pointing at the row is about).
        if let display {
            parts.insert("Display \(display)", at: 0)
            while parts.count > 1, !fits(parts.joined(separator: " · ")) { parts.remove(at: 1) }
        }
        return parts.joined(separator: " · ")
    }

    /// Room for a row's second line: the menu's width less the icon column and the submenu arrow.
    static let detailWidth = MenuHeroView.width(previewWidth: thumbWidth) - 48 - 40

    /// Cut in the middle until it fits `width` points in `font`, so no row widens the menu.
    static func fitted(_ text: String, font: NSFont, width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        guard w(text) > width else { return text }
        var limit = text.count
        while limit > 4 {
            limit -= 1
            let t = clipped(text, to: limit)
            if w(t) <= width { return t }
        }
        return clipped(text, to: 4)
    }

    /// Long names are cut in the middle, so the menu keeps its width and the picture its place.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2, tail = limit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        guard refreshTimer == nil else { return }
        openedAt = ProcessInfo.processInfo.systemUptime
        captureFailureLogged = false
        hero?.preview?.reduceMotion = meter?.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshThumbnails()
            self?.refreshText()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)   // keeps firing while the menu is tracking
        refreshTimer = t
        refreshThumbnails()
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        thumbnailGeneration += 1
        captureQueue = []
        page = 0
        for preview in hero?.previews ?? [] {
            preview.highlighted = []
            preview.resetPointer()
            preview.message = nil
            preview.isStale = preview.hasImage
        }
    }

    deinit { refreshTimer?.invalidate() }

    /// Pointing at an app's row picks its windows out in the picture.
    /// With several displays, only its display's picture; one that's on another page lights the
    /// arrow toward it instead (the menu doesn't page by itself).
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let pid = item.flatMap { item in rows.first { $0.value === item }?.key }
        let slot = pid.flatMap { p in daemon?.registry.first { $0.pid == p } }.map { $0.display ?? (daemon?.display.slot ?? 1) }
        for (i, preview) in (hero?.previews ?? []).enumerated() {
            preview.highlighted = pid != nil && visibleSlots.indices.contains(i) && visibleSlots[i] == slot ? [pid!] : []
        }
        var toward = 0
        if let slot, !visibleSlots.contains(slot), let all = daemon?.allDisplays.map({ $0.slot }),
           let at = all.firstIndex(of: slot), let first = visibleSlots.first, let firstAt = all.firstIndex(of: first) {
            toward = at < firstAt ? -1 : 1
        }
        updatePager(toward: toward)
    }

    private func rebuild() {
        thumbnailGeneration += 1
        menu.removeAllItems()
        guard let d = daemon else { return }
        // This daemon's displays only: other homes' daemons show theirs in their own menus.
        let id = d.display.id
        let b = CGDisplayBounds(id)
        let area = CGSize(width: b.width, height: b.height - Self.menuBarHeight(id))
        let count = d.allDisplays.count
        let shape = (CGDisplayIsActive(id) != 0 && area.width > 0 && area.height > 0 ? "\(area.width)x\(area.height)" : "none")
            + (count > 2 ? "|paged" : count > 1 ? "|stacked" : "")
        if hero == nil || shape != heroShape {
            let item = NSMenuItem()
            let view = MenuHeroView(previewWidth: Self.thumbWidth, aspect: shape.hasPrefix("none") ? nil : area.width / area.height,
                                    stacked: count > 1, paged: count > 2, onPage: { [weak self] delta in self?.turnPage(delta) })
            item.view = view
            hero = view
            heroItem = item
            heroShape = shape
        }
        if let heroItem { menu.addItem(heroItem) }
        showPage()
        rebuildRows()
    }

    /// Which displays a page shows, `perPage` at a time.
    struct Page: Equatable {
        let page: Int, visible: [Int], first: Int, last: Int, total: Int, canBack: Bool, canForward: Bool
    }
    static func page(_ requested: Int, of slots: [Int], perPage: Int) -> Page {
        guard perPage > 0, !slots.isEmpty else { return Page(page: 0, visible: [], first: 0, last: 0, total: slots.count, canBack: false, canForward: false) }
        let pages = (slots.count + perPage - 1) / perPage
        let p = min(max(requested, 0), pages - 1)
        let visible = Array(slots[(p * perPage)..<min(slots.count, p * perPage + perPage)])
        return Page(page: p, visible: visible, first: p * perPage + 1, last: p * perPage + visible.count, total: slots.count,
                    canBack: p > 0, canForward: p < pages - 1)
    }

    /// Point the pictures at the current page's displays (labels, cached pictures, pager).
    private func showPage() {
        guard let d = daemon, let hero else { return }
        let slots = d.allDisplays.map { $0.slot }
        guard slots.count > 1 else { visibleSlots = [d.display.slot]; return }
        let perPage = hero.previews.count
        let shown = Self.page(page, of: slots, perPage: perPage)
        page = shown.page
        visibleSlots = shown.visible
        let apps = d.registry.filter { $0.matchesProcess }
        for i in 0..<perPage {
            guard i < visibleSlots.count else { hero.setLabel(nil, at: i); continue }
            let slot = visibleSlots[i]
            let n = apps.filter { ($0.display ?? d.display.slot) == slot }.count
            var text = "Display \(slot) · \(n == 1 ? "1 app" : "\(n) apps")"
            if d.reservations[slot].map({ $0.until > Date().timeIntervalSince1970 }) == true { text += " · reserved" }
            hero.setLabel(text, at: i)
            let preview = hero.previews[i]
            if let image = lastImages[slot], preview.shownSlot != slot {
                preview.setImage(image)
                preview.isStale = true
            } else if preview.shownSlot != slot {
                preview.clearImage()
            }
            preview.shownSlot = slot
        }
        updatePager()
    }

    private func updatePager(toward: Int = 0) {
        guard let d = daemon, let hero else { return }
        let slots = d.allDisplays.map { $0.slot }
        guard slots.count > 2 else { return }
        let shown = Self.page(page, of: slots, perPage: hero.previews.count)
        hero.setPage(first: shown.first, last: shown.last, of: shown.total, canBack: shown.canBack, canForward: shown.canForward, toward: toward)
    }

    private func turnPage(_ delta: Int) {
        page += delta
        thumbnailGeneration += 1
        captureQueue = []
        showPage()
        refreshThumbnails()
    }

    /// Everything below the picture. Also run while the menu is open, when apps come or go.
    private func rebuildRows() {
        while menu.numberOfItems > 1 { menu.removeItem(at: menu.numberOfItems - 1) }
        rows.removeAll()
        let apps = daemon?.registry.filter { $0.matchesProcess } ?? []
        rowsKey = Self.key(apps)
        if apps.isEmpty {
            let none = NSMenuItem(title: "No apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for group in Self.groups(apps) {
            menu.addItem(.sectionHeader(title: Self.fitted(group.label, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                                                            width: MenuHeroView.width(previewWidth: Self.thumbWidth) - 32)))
            for app in group.apps {
                let row = self.row(for: app)
                rows[app.pid] = row
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(sendItem())
        let folder = NSMenuItem(title: "Open Screenshots & Logs Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        // On its own: it ends every agent's work in progress.
        menu.addItem(.separator())
        let keep = daemon?.keepActive == true
        let stop = NSMenuItem(title: "Quit All Agent Apps", action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = !apps.isEmpty
        stop.toolTip = "Quits every app running here, including apps you sent backstage"
            + (keep ? ". Backstage stays in the menu bar." : ", and removes the hidden display.")
            + " Apps on your screen aren't touched."
        menu.addItem(stop)
        menu.addItem(.separator())
        let keepItem = NSMenuItem(title: "Keep in Menu Bar", action: #selector(toggleKeep), keyEquivalent: "")
        keepItem.target = self
        keepItem.state = daemon?.settings.keep == true ? .on : .off
        keepItem.toolTip = "Keeps Backstage here with no apps running, so Send Front Window Backstage and its shortcut are always at hand. "
            + "After a restart, `backstage start` brings it back."
        menu.addItem(keepItem)
        menu.addItem(.separator())
        let footer = NSMenuItem()
        footer.view = MenuFooterView(width: MenuHeroView.width(previewWidth: Self.thumbWidth)) { [weak self] in
            self?.menu.cancelTracking()
            NSWorkspace.shared.open(backstageRepoURL)
        }
        menu.addItem(footer)
        refreshText(apps: apps)
    }

    private static func key(_ apps: [ManagedApp]) -> [String] {
        apps.map { "\($0.pid)/\($0.processStart ?? 0)/\($0.owner)" }.sorted()
    }

    private func row(for app: ManagedApp) -> NSMenuItem {
        let name = Self.fitted(app.name, font: .menuFont(ofSize: 0), width: Self.detailWidth)
        let row = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        // Two lines (name, then what it's doing) where the system has subtitles, with an icon to match.
        var iconSize: CGFloat = 16
        if #available(macOS 14.4, *) { iconSize = 26 }
        let running = NSRunningApplication(processIdentifier: app.pid)
        if let icon = (running?.icon ?? running?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) })?.copy() as? NSImage {
            icon.size = NSSize(width: iconSize, height: iconSize)
            row.image = icon
        }

        let sub = NSMenu()
        sub.autoenablesItems = false
        func action(_ title: String, _ selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = app
            return item
        }
        let show = action("Show on My Screen", #selector(showApp(_:)))
        show.toolTip = (Session.isUser(app.session) ? "Brings \(name) back to your screen: agents can no longer use it. "
                        : "Moves \(name) to your screen and hands it over to you: agents can no longer use it. ")
            + (app.audioMode == .inaudible ? "It stays silent until it's relaunched." : "You'll hear its sound again.")
        sub.addItem(show)
        sub.addItem(.separator())
        sub.addItem(action("Quit \(name)", #selector(quitApp(_:))))
        // Hold Option, as in the Apple menu.
        let force = action("Force Quit \(name)", #selector(forceQuitApp(_:)))
        force.isAlternate = true
        force.keyEquivalentModifierMask = [.option]
        sub.addItem(force)
        sub.addItem(.separator())
        // For the developer who needs them; nowhere else in the menu.
        let info = NSMenuItem(title: Self.clipped(app.bundleID ?? URL(fileURLWithPath: app.path).lastPathComponent, to: 44) + " · PID \(app.pid)",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        row.submenu = sub
        return row
    }

    /// The sentence at the top and each row's second line: at each rebuild, and once a second
    /// while the menu is open. AppKit is touched only for what changed.
    private func refreshText(apps current: [ManagedApp]? = nil) {
        guard let d = daemon else { return }
        let apps = current ?? d.registry.filter { $0.matchesProcess }
        guard Self.key(apps) == rowsKey else { rebuildRows(); return }
        hero?.status = Self.summary(apps)

        var windows: [pid_t: Int] = [:]
        for window in managedWindows(of: apps) { windows[window.pid, default: 0] += 1 }
        // Only apps launched with --audio are measured; the others never show as playing.
        var playing: Set<pid_t> = []
        for sample in meter?.samples() ?? [] where sample.playing { playing.insert(sample.pid) }
        let now = Date().timeIntervalSince1970
        for app in apps {
            guard let row = rows[app.pid] else { continue }
            let multi = d.allDisplays.count > 1
            let detail = Self.detail(launchedAt: app.launchedAt, now: now, windows: windows[app.pid] ?? 0, playing: playing.contains(app.pid),
                                     sent: Session.isUser(app.session), display: multi ? (app.display ?? d.display.slot) : nil)
            if #available(macOS 14.4, *) {
                if row.subtitle != detail { row.subtitle = detail }
            } else if row.toolTip != detail {
                row.toolTip = detail
            }
        }

        if d.allDisplays.count > 1 { showPage() }
        // A picture that has stopped updating says so, rather than passing for live.
        if refreshTimer != nil {
            let since = max(lastFrame, openedAt)
            if ProcessInfo.processInfo.systemUptime - since > 3.5 + Double(visibleSlots.count - 1) {
                for preview in hero?.previews ?? [] where !preview.isHidden {
                    preview.isStale = false
                    preview.message = preview.hasImage ? "Preview paused" : "Preview unavailable"
                }
            }
        }
    }

    /// These apps' windows on this daemon's display, front to back, from one pass over the
    /// window list: no call into the apps, so a hung app can't hold up the menu.
    private func managedWindows(of apps: [ManagedApp]) -> [(pid: pid_t, bounds: CGRect)] {
        guard let d = daemon, !apps.isEmpty else { return [] }
        let displays = d.allDisplays.map { $0.bounds }
        let pids = Set(apps.map { $0.pid })
        return onscreenWindows().compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            let bounds = cgBounds(window)
            guard displays.contains(where: { $0.intersects(bounds) }) else { return nil }
            return (pid, bounds)
        }
    }

    /// Where each managed window is in the picture, front to back.
    private func regions(slot: Int) -> [DisplayPreviewView.Region] {
        guard let d = daemon, let shown = d.allDisplays.first(where: { $0.slot == slot }) else { return [] }
        let id = shown.id
        let display = CGDisplayBounds(id)
        let bar = Self.menuBarHeight(id)
        let area = CGRect(x: display.minX, y: display.minY + bar, width: display.width, height: display.height - bar)
        guard area.width > 0, area.height > 0 else { return [] }
        let apps = d.registry.filter { $0.matchesProcess && ($0.display ?? d.display.slot) == slot }
        let names = Dictionary(apps.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return managedWindows(of: apps).compactMap { window in
            let r = window.bounds.intersection(area)
            guard !r.isNull, r.width >= 8, r.height >= 8, let name = names[window.pid] else { return nil }
            return .init(pid: window.pid, name: name,
                         rect: CGRect(x: (r.minX - area.minX) / area.width, y: (r.minY - area.minY) / area.height,
                                      width: r.width / area.width, height: r.height / area.height))
        }
    }

    /// Capture in a child so a stuck ScreenCaptureKit call dies with its process. The child
    /// retains both capture locks until exit, and we wait for exit before starting another.
    /// The picture is captured at its own size in the pixels of the screen the menu is on, so
    /// it's as sharp as that screen can show it.
    private func refreshThumbnails() {
        guard captureQueue.isEmpty else { return }   // last round still going
        captureQueue = visibleSlots.enumerated().map { (index: $0.offset, slot: $0.element) }
        captureNext()
    }

    /// One capture in flight at a time; a result for a picture that now shows another display
    /// (the page turned) is dropped.
    private func captureNext() {
        guard !capturing, !captureQueue.isEmpty, let d = daemon, let hero else { return }
        let (index, slot) = captureQueue.removeFirst()
        guard hero.previews.indices.contains(index), let shown = d.allDisplays.first(where: { $0.slot == slot }) else { captureNext(); return }
        let preview = hero.previews[index]
        let id = shown.id
        var executable = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &executable, UInt32(executable.count)) > 0 else { return }
        let size = preview.bounds.size
        let scale = min(2, preview.window?.backingScaleFactor ?? item.button?.window?.backingScaleFactor ?? 2)
        let generation = thumbnailGeneration
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: String(cString: executable))
        process.arguments = ["__menu-thumbnail", String(id), String(Double(Self.menuBarHeight(id))),
                             String(Int(size.width * scale)), String(Int(size.height * scale))]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        capturing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = try? output.fileHandleForReading.readToEnd()
            process.waitUntilExit()
            let status = process.terminationStatus
            let image: CGImage? = autoreleasepool {
                guard status == 0, let data, !data.isEmpty,
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.capturing = false
                guard self.refreshTimer != nil else { return }
                defer { self.captureNext() }
                guard generation == self.thumbnailGeneration else { return }
                guard let image else {
                    // Status 0 without a picture: another capture had the lock, so this one was skipped.
                    if status != 0, !self.captureFailureLogged {
                        self.captureFailureLogged = true
                        self.daemon?.log("menu preview: capture failed (status \(status))")
                    }
                    return
                }
                self.lastImages[slot] = image
                guard self.visibleSlots.indices.contains(index), self.visibleSlots[index] == slot,
                      let preview = self.hero?.previews[safe: index] else { return }
                self.lastFrame = ProcessInfo.processInfo.systemUptime
                preview.message = nil
                preview.setImage(image)
                preview.shownSlot = slot
                preview.regions = self.regions(slot: slot)
            }
        }
    }

    // MARK: actions (user-initiated)

    private func currentApp(_ sender: NSMenuItem) -> ManagedApp? {
        guard let selected = sender.representedObject as? ManagedApp,
              let record = daemon?.registry.first(where: { $0.pid == selected.pid }),
              record.processStart == selected.processStart, record.launchedAt == selected.launchedAt,
              record.matchesProcess else { return nil }
        return record
    }

    /// "Send Front Window Backstage", with the hotkey beside it when it's registered. Disabled,
    /// with the reason in its tooltip, when the frontmost app is one that's never sent.
    private func sendItem() -> NSMenuItem {
        let send = NSMenuItem(title: "Send Front Window Backstage", action: #selector(sendFront), keyEquivalent: "")
        send.target = self
        if let combo = daemon?.hotKey?.registered {
            send.keyEquivalent = combo.keyEquivalent
            send.keyEquivalentModifierMask = combo.modifierMask
        }
        var tip = "Moves the frontmost app, with all its windows, to the hidden display, where agents can use it "
            + "(`backstage list --all`, then `--pid`). It's muted; Show on My Screen brings it back."
        if let error = daemon?.hotkeyError { tip += "\nShortcut unavailable: \(error)" }
        if let front = NSWorkspace.shared.frontmostApplication {
            let path = front.bundleURL?.path ?? front.executableURL?.path
            if front.processIdentifier == getpid() || daemon?.managed.contains(front.processIdentifier) == true {
                send.isEnabled = false
            } else if let why = sendRefusal(bundleID: front.bundleIdentifier, name: front.localizedName, path: path) {
                send.isEnabled = false
                tip = "Can't send \(front.localizedName ?? "the frontmost app") backstage: \(why)."
            }
        }
        send.toolTip = tip
        return send
    }

    @objc private func sendFront() {
        daemon?.sendFrontWindowBackstage(from: "menu")
    }

    @objc private func toggleKeep() {
        guard let d = daemon else { return }
        var settings = Settings.load()
        settings.keepInMenuBar = !d.settings.keep
        do { try settings.save() } catch { d.log("couldn't save settings: \(error)"); return }
        d.applySettings()
    }

    @objc private func showApp(_ sender: NSMenuItem) {
        guard let rec = currentApp(sender) else { NSSound.beep(); return }
        do { try handOver(rec, wait: false) } catch { NSSound.beep(); daemon?.log("menu show failed (busy launch/stop?): \(error)") }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let rec = currentApp(sender) else { return }
        do { try rec.requestTermination(force: false) } catch { daemon?.log("menu quit failed: \(error)") }
    }

    @objc private func forceQuitApp(_ sender: NSMenuItem) {
        guard let rec = currentApp(sender) else { return }
        do { try rec.requestTermination(force: true) } catch { daemon?.log("menu force quit failed: \(error)") }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Paths.dir)
    }

    @objc private func stopAll() {
        guard let d = daemon else { return }
        // With Keep in Menu Bar on, the apps go but Backstage stays.
        if d.keepActive { d.quitAllApps() } else { d.shutdown(reason: "stopped from the menu bar") }
    }
}

/// Internal child entry point. Exit under the locks even if the asynchronous capture times out.
func runMenuThumbnail(_ args: Args) throws {
    guard let id = args.pos(0).flatMap(CGDirectDisplayID.init),
          let menuBar = args.pos(1).flatMap(Double.init), menuBar.isFinite, menuBar >= 0,
          let width = args.pos(2).flatMap(Int.init), (1...Int(StatusMenu.thumbWidth * 2)).contains(width),
          let height = args.pos(3).flatMap(Int.init), (1...4096).contains(height) else {
        throw CLIError("invalid thumbnail dimensions")
    }
    guard let daemon = liveDaemon(), daemon.pid == getppid(), daemon.stopping != true,
          daemon.displayID == id || daemon.displays?.contains(where: { $0.displayID == id }) == true else {
        throw CLIError("thumbnail capture must target the parent daemon's live backstage display")
    }
    guard let lock = try? StateLock("capture.lock", nonblocking: true),
          let userLock = UserLock("capture.lock", nonblocking: true) else { return }
    withExtendedLifetime((lock, userLock)) {
        guard let image = try? runAsync(timeout: captureAttemptTimeout, {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CLIError("display unavailable")
            }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > menuBar else { throw CLIError("display unavailable") }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: menuBar, width: bounds.width, height: bounds.height - menuBar)
            config.width = width
            config.height = height
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config
            )
        }), let data = CFDataCreateMutable(nil, 0),
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
        do { try FileHandle.standardOutput.write(contentsOf: data as Data) }
        catch { exit(1) }
        exit(0)
    }
}

/// TEST ONLY (`__menu-render`): the top of the menu with `--displays N` synthetic displays on
/// page `--page P`, rendered to `-o file.png`, so layouts for 1-8 displays are checked without
/// creating any. Prints the view's size, each picture's frame and what's shown.
func runMenuRender(_ args: Args) throws -> [String: Any] {
    _ = NSApplication.shared
    let n = max(1, min(8, args.int("displays") ?? 1))
    let slots = Array(1...n)
    let view = MenuHeroView(previewWidth: StatusMenu.thumbWidth, aspect: 16.0 / 10, stacked: n > 1, paged: n > 2)
    // Offscreen there's no window to take the appearance from; the menu's own follows the system.
    view.appearance = NSAppearance(named: args.opt("appearance") == "dark" ? .darkAqua : .aqua)
    let shown = StatusMenu.page(args.int("page") ?? 0, of: n > 1 ? slots : [1], perPage: view.previews.count)
    let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal, .systemYellow, .systemRed]
    for (i, preview) in view.previews.enumerated() {
        if n > 1 { view.setLabel(i < shown.visible.count ? "Display \(shown.visible[i]) · \(i + 1) apps" : nil, at: i) }
        guard i < shown.visible.count else { continue }
        let size = CGSize(width: 64, height: 40)
        let image = NSImage(size: size, flipped: false) { r in colors[(shown.visible[i] - 1) % colors.count].setFill(); r.fill(); return true }
        var rect = CGRect(origin: .zero, size: size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { preview.setImage(cg) }
    }
    if n > 2 { view.setPage(first: shown.first, last: shown.last, of: shown.total, canBack: shown.canBack, canForward: shown.canForward) }
    view.layoutSubtreeIfNeeded()
    if let out = args.opt("o"), let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    }
    return ["width": view.bounds.width, "height": view.bounds.height, "visible": shown.visible,
            "first": shown.first, "last": shown.last, "canBack": shown.canBack, "canForward": shown.canForward,
            "previews": view.previews.map { ["y": $0.frame.minY, "height": $0.frame.height, "hidden": $0.isHidden] },
            "pager": view.pagerFrames ?? NSNull()]
}
