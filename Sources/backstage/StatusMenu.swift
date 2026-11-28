import Foundation
import AppKit
import QuartzCore
import ScreenCaptureKit
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Menu bar indicator owned by the daemon. Visible while apps are running backstage, or always
/// with Auto-Hide When Idle off.
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
    // A 640×480 BGRA preview is 1.23 MB before encoding. Bound the parent's reads while
    // leaving room for PNG framing and the capture's embedded color profile.
    fileprivate static let thumbnailByteLimit = 2 * 1024 * 1024
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
    private struct PreviewSource: Equatable {
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let active: Bool
        let menuBarHeight: CGFloat
        let apps: [ManagedApp]
    }
    private var previewSources: [Int: PreviewSource] = [:]
    private var lastImages: [Int: CGImage] = [:]
    private var captureQueue: [(index: Int, slot: Int)] = []
    /// Each app's row, and what the rows were built from (to notice apps coming and going).
    private var rows: [pid_t: NSMenuItem] = [:]
    /// The app list scrolls in place when it's longer than its share of the screen: only a window
    /// of its entries (session headings and app rows, all native items with real submenus) is in
    /// the menu, between ▲ and ▼ items that move the window while pointed at, as a long menu's
    /// own arrows do, but within the list, so the picture and the actions stay put.
    private enum ListEntry { case heading(String, Int), app(ManagedApp) }
    private var listEntries: [ListEntry] = []
    private var listOffset = 0
    private var listItems: [NSMenuItem] = []
    private let listUp = NSMenuItem(title: "", action: #selector(scrollListUp), keyEquivalent: "")
    private let listDown = NSMenuItem(title: "", action: #selector(scrollListDown), keyEquivalent: "")
    private var listScrollTimer: Timer?
    private var rowsKey: [String] = []
    private var openedAt = 0.0
    /// When each display's picture last updated (each is checked for freshness on its own).
    private var lastFrames: [Int: Double] = [:]
    private var captureFailureLogged = false

    init(daemon: Daemon) {
        self.daemon = daemon
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.isVisible = false
        fakeAudio = FakeAudioSource(daemon: daemon, spec: ProcessInfo.processInfo.environment["BACKSTAGE_FAKE_AUDIO"])
        if fakeAudio != nil { daemon.log("audio meter: using the test-only fake audio source (BACKSTAGE_FAKE_AUDIO)") }
        if let button = item.button {
            // A display behind a display, the one behind dashed and 70% transparent: the hidden one. Drawn into a
            // plain image, like every meter frame, so the icon's box never changes; the number of
            // running apps sits beside it (the width changes only when the count gains a digit).
            let img = AudioMeter.symbolImage("rectangle.on.rectangle.dashed", description: "Backstage", secondaryOpacity: 0.3)
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
            // apps (Auto-Hide When Idle off), the icon stands alone: no "0".
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
        let reduceMotion = meter?.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for preview in hero?.previews ?? [] { preview.reduceMotion = reduceMotion }
        showPage()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshText()
            self?.refreshThumbnails()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)   // keeps firing while the menu is tracking
        refreshTimer = t
        refreshThumbnails()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopListScroll()
        listOffset = 0
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

    deinit {
        refreshTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Pointing at an app's row picks its windows out in the picture.
    /// With several displays, only its display's picture; one that's on another page lights the
    /// arrow toward it instead (the menu doesn't page by itself).
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if item === listUp, listUp.isEnabled { startListScroll(-1) }
        else if item === listDown, listDown.isEnabled { startListScroll(1) }
        else { stopListScroll() }
        highlight(pid: item.flatMap { item in rows.first { $0.value === item }?.key })
    }

    func highlight(pid: pid_t?) {
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
        captureQueue.removeAll()
        menu.removeAllItems()
        guard let d = daemon else { return }
        let displays = d.allDisplays
        let apps = d.registry.filter { $0.matchesProcess }
        let sources = Self.previewSources(displays: displays, primary: d.display.slot, apps: apps)
        let count = displays.count
        let (shape, aspect) = Self.previewLayout(primary: sources[d.display.slot], count: count)
        if hero == nil || shape != heroShape {
            let item = NSMenuItem()
            let view = MenuHeroView(previewWidth: Self.thumbWidth, aspect: aspect,
                                    stacked: count > 1, paged: count > 2, onPage: { [weak self] delta in self?.turnPage(delta) })
            item.view = view
            let reduceMotion = meter?.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for preview in view.previews { preview.reduceMotion = reduceMotion }
            hero = view
            heroItem = item
            heroShape = shape
            // Two pictures side by side make the menu a little wider; one keeps it as it was.
            menu.minimumWidth = max(MenuHeroView.width(previewWidth: Self.thumbWidth), view.frame.width)
        }
        if let heroItem { menu.addItem(heroItem) }
        showPage(displays: displays, sources: sources)
        rebuildRows(apps: apps)
    }

    private static func previewLayout(primary: PreviewSource?, count: Int) -> (shape: String, aspect: CGFloat?) {
        let width = primary?.bounds.width ?? 0
        let height = (primary?.bounds.height ?? 0) - (primary?.menuBarHeight ?? 0)
        let visible = primary?.active == true && width > 0 && height > 0
        let dimensions = visible ? "\(width)x\(height)" : "none"
        let layout = count > 2 ? "|paged" : count > 1 ? "|stacked" : ""
        return (dimensions + layout, visible ? width / height : nil)
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

    private static func previewSources(displays: [AgentDisplay], primary: Int, apps: [ManagedApp]) -> [Int: PreviewSource] {
        let groups = Dictionary(grouping: apps) { $0.display ?? primary }
        return Dictionary(uniqueKeysWithValues: displays.map { display in
            (display.slot, PreviewSource(displayID: display.id, bounds: CGDisplayBounds(display.id),
                                         active: CGDisplayIsActive(display.id) != 0,
                                         menuBarHeight: Self.menuBarHeight(display.id),
                                         apps: (groups[display.slot] ?? []).sorted { $0.pid < $1.pid }))
        })
    }

    private func showPage() {
        guard let d = daemon else { return }
        let displays = d.allDisplays
        let sources = Self.previewSources(displays: displays, primary: d.display.slot, apps: d.registry.filter { $0.matchesProcess })
        showPage(displays: displays, sources: sources)
    }

    /// Point the pictures at the current page's displays (labels, cached pictures, pager).
    private func showPage(displays: [AgentDisplay], sources: [Int: PreviewSource]) {
        guard let d = daemon, let hero else { return }
        let shown = Self.page(page, of: displays.map(\.slot), perPage: hero.previews.count)
        if visibleSlots != shown.visible { openedAt = ProcessInfo.processInfo.systemUptime }
        if sources != previewSources || visibleSlots != shown.visible {
            thumbnailGeneration += 1
            captureQueue.removeAll()
            for (slot, source) in previewSources where sources[slot] != source {
                lastImages[slot] = nil
                lastFrames[slot] = nil
                for preview in hero.previews where preview.shownSlot == slot {
                    preview.shownSlot = nil
                    preview.clearImage()
                }
            }
            previewSources = sources
        }
        page = shown.page
        visibleSlots = shown.visible
        for (i, preview) in hero.previews.enumerated() {
            // Extra displays get an ⓧ; the primary always stays.
            let slotHere = visibleSlots[safe: i]
            if let slot = slotHere, slot != d.display.slot {
                let n = sources[slot]?.apps.count ?? 0
                preview.onClose = { [weak self] in self?.closeDisplay(slot) }
                preview.closeToolTip = "Close Display \(slot)" + (n == 0 ? "" : n == 1 ? ": its app moves to Display \(d.display.slot)"
                                                                  : ": its \(n) apps move to Display \(d.display.slot)")
            } else {
                preview.onClose = nil
            }
            guard let slot = slotHere else {
                hero.setLabel(nil, at: i)
                if preview.shownSlot != nil {
                    preview.shownSlot = nil
                    preview.clearImage()
                }
                continue
            }
            if displays.count > 1 {
                let n = sources[slot]?.apps.count ?? 0
                var text = "Display \(slot) · \(n == 1 ? "1 app" : "\(n) apps")"
                if d.reservations[slot].map({ $0.until > Date().timeIntervalSince1970 }) == true { text += " · reserved" }
                hero.setLabel(text, at: i)
            }
            guard preview.shownSlot != slot else { continue }
            preview.clearImage()
            preview.shownSlot = slot
            if let image = lastImages[slot] {
                preview.setImage(image)
                preview.isStale = true
            }
        }
        if shown.total > 2 {
            hero.setPage(first: shown.first, last: shown.last, of: shown.total,
                         canBack: shown.canBack, canForward: shown.canForward)
        }
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
    private func rebuildRows(apps: [ManagedApp]) {
        rowsKey = Self.key(apps)
        while menu.numberOfItems > 1 { menu.removeItem(at: menu.numberOfItems - 1) }
        rows.removeAll()
        listItems = []
        listEntries = []
        if apps.isEmpty {
            let none = NSMenuItem(title: "No apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for group in Self.groups(apps) {
                listEntries.append(.heading(group.label, group.apps.count))
                for app in group.apps { listEntries.append(.app(app)) }
            }
            listOffset = min(listOffset, max(0, listEntries.count - 1))
            layOutList()
        }
        addFixedItems(apps: apps)
        refreshText(apps: apps)
    }

    /// Approximate heights of the list's items, in points, to fit its share of the screen.
    private static let rowPoints: CGFloat = 38, headingPoints: CGFloat = 24, arrowPoints: CGFloat = 20

    /// The list's most height: 40% of the screen under the menu bar icon, so the whole menu fits
    /// with room to spare however many apps there are.
    static func listMaxHeight(screen: NSScreen?) -> CGFloat {
        let height = (screen ?? NSScreen.main)?.frame.height ?? 900
        return max(rowPoints * 4, (height * 0.4).rounded())
    }

    private func entryPoints(_ entry: ListEntry) -> CGFloat {
        if case .heading = entry { return Self.headingPoints }
        return Self.rowPoints
    }

    /// Put the window of entries starting at `listOffset` into the menu (just after the picture),
    /// with ▲/▼ when there's more above or below.
    private func layOutList() {
        for item in listItems { menu.removeItem(item) }
        listItems = []
        let budget = Self.listMaxHeight(screen: item.button?.window?.screen)
        let total = listEntries.reduce(CGFloat(0)) { $0 + entryPoints($1) }
        var window: [ListEntry] = []
        if total <= budget {
            listOffset = 0
            window = listEntries
        } else {
            // Keep a full window: don't scroll past the point where the last entry is at the bottom.
            var room = budget - 2 * Self.arrowPoints
            var lastStart = listEntries.count
            while lastStart > 0, room - entryPoints(listEntries[lastStart - 1]) >= 0 {
                lastStart -= 1
                room -= entryPoints(listEntries[lastStart])
            }
            listOffset = min(max(listOffset, 0), lastStart)
            room = budget - 2 * Self.arrowPoints
            // A window that starts inside a session repeats its heading on top, for context.
            if case .app = listEntries[listOffset],
               let heading = listEntries[..<listOffset].lastIndex(where: { if case .heading = $0 { return true }; return false }) {
                window.append(listEntries[heading])
                room -= Self.headingPoints
            }
            var index = listOffset
            while index < listEntries.count, room - entryPoints(listEntries[index]) >= 0 {
                window.append(listEntries[index])
                room -= entryPoints(listEntries[index])
                index += 1
            }
            let above = listOffset, below = listEntries.count - index
            configureArrow(listUp, symbol: "chevron.up", more: listEntries[..<above], enabled: above > 0)
            configureArrow(listDown, symbol: "chevron.down", more: listEntries[index...], enabled: below > 0)
            listItems.append(listUp)
        }
        for entry in window {
            switch entry {
            case let .heading(label, count):
                let heading = NSMenuItem.sectionHeader(title: Self.fitted(label, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                                                                          width: MenuHeroView.width(previewWidth: Self.thumbWidth) - 72))
                heading.badge = NSMenuItemBadge(count: count)
                listItems.append(heading)
            case let .app(app):
                let row = rows[app.pid] ?? self.row(for: app)
                rows[app.pid] = row
                listItems.append(row)
            }
        }
        if total > budget { listItems.append(listDown) }
        for (i, item) in listItems.enumerated() { menu.insertItem(item, at: 1 + i) }
    }

    private func configureArrow(_ arrow: NSMenuItem, symbol: String, more: ArraySlice<ListEntry>, enabled: Bool) {
        let apps = more.filter { if case .app = $0 { return true }; return false }.count
        arrow.target = self
        arrow.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        arrow.title = enabled ? "\(apps) more" : ""
        arrow.isEnabled = enabled
        arrow.toolTip = enabled ? "Point here to scroll the list" : nil
        arrow.setAccessibilityLabel(enabled ? "Scroll the app list, \(apps) more" : "Top of the app list")
    }

    @objc private func scrollListUp() { scrollList(by: -1) }
    @objc private func scrollListDown() { scrollList(by: 1) }

    private func scrollList(by delta: Int) {
        let before = listOffset
        listOffset = max(0, listOffset + delta)
        layOutList()
        if listOffset == before { stopListScroll() }
        refreshText()
    }

    /// While ▲ or ▼ is highlighted, the list moves an entry every 0.12 s.
    private func startListScroll(_ delta: Int) {
        stopListScroll()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.scrollList(by: delta) }
        RunLoop.main.add(timer, forMode: .common)
        listScrollTimer = timer
    }

    private func stopListScroll() {
        listScrollTimer?.invalidate()
        listScrollTimer = nil
    }

    private func addFixedItems(apps: [ManagedApp]) {
        menu.addItem(.separator())
        menu.addItem(sendItem())
        menu.addItem(sendToItem())
        let recover = NSMenuItem(title: "Recover Lost Windows", action: #selector(recoverWindows), keyEquivalent: "")
        recover.target = self
        recover.toolTip = "Brings windows of apps backstage isn't running back to your screen when they've ended up on a hidden display "
            + "(an app reopening where it last was). Backstage returns them by itself after a few seconds; this does it now."
        menu.addItem(recover)
        let folder = NSMenuItem(title: "Open Screenshots & Logs Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        // On its own: it ends every agent's work in progress.
        menu.addItem(.separator())
        let keep = daemon?.keepActive == true
        let stop = NSMenuItem(title: "Quit All Apps", action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = !apps.isEmpty
        stop.toolTip = "Quits every app running here, including apps you sent backstage"
            + (keep ? ". Backstage stays in the menu bar." : ", and removes the hidden display.")
            + " Apps on your screen aren't touched."
        menu.addItem(stop)
        menu.addItem(.separator())
        let keepItem = NSMenuItem(title: "Auto-Hide When Idle", action: #selector(toggleKeep), keyEquivalent: "")
        keepItem.target = self
        // A trailing checkmark, not the item's state: a state image makes the menu reserve a
        // checkmark column, which indents every row and unbalances the menu.
        let autoHide = daemon?.settings.autoHide == true
        if autoHide { keepItem.badge = NSMenuItemBadge(string: "✓") }
        keepItem.setAccessibilityValue(autoHide ? "on" : "off")
        keepItem.toolTip = autoHide
            ? "Backstage leaves the menu bar when no apps are running, and quits after a while idle. Uncheck to keep it here, with Send Front Window Backstage and its shortcut always at hand."
            : "Backstage stays here with no apps running, so Send Front Window Backstage and its shortcut are always at hand. Check to hide it when no apps are running."
        menu.addItem(keepItem)
        menu.addItem(.separator())
        let footer = NSMenuItem()
        footer.view = MenuFooterView(width: MenuHeroView.width(previewWidth: Self.thumbWidth)) { [weak self] in
            self?.menu.cancelTracking()
            NSWorkspace.shared.open(backstageRepoURL)
        }
        menu.addItem(footer)
    }

    private static func key(_ apps: [ManagedApp]) -> [String] {
        apps.map { "\($0.pid)/\($0.processStart ?? 0)/\($0.owner)" }.sorted()
    }

    private func row(for app: ManagedApp, compact: Bool = false) -> NSMenuItem {
        let name = Self.fitted(app.name, font: .menuFont(ofSize: 0), width: Self.detailWidth)
        let row = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        // Two lines (name, then what it's doing) where the system has subtitles, with an icon to
        // match; one line with a small icon when the menu is short of room.
        var iconSize: CGFloat = 16
        if #available(macOS 14.4, *), !compact { iconSize = 26 }
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
        sub.addItem(moveItem(for: app, name: name))
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
        guard Self.key(apps) == rowsKey else { rebuildRows(apps: apps); return }
        let displays = d.allDisplays
        let sources = Self.previewSources(displays: displays, primary: d.display.slot, apps: apps)
        if Self.previewLayout(primary: sources[d.display.slot], count: displays.count).shape != heroShape {
            rebuild()
            return
        }
        hero?.status = Self.summary(apps)

        var windows: [pid_t: Int] = [:]
        for window in managedWindows(of: apps, on: sources.values.map(\.bounds)) { windows[window.pid, default: 0] += 1 }
        // Only apps launched with --audio are measured; the others never show as playing.
        var playing: Set<pid_t> = []
        for sample in meter?.samples() ?? [] where sample.playing { playing.insert(sample.pid) }
        let now = Date().timeIntervalSince1970
        let multi = displays.count > 1
        for app in apps {
            guard let row = rows[app.pid] else { continue }
            let detail = Self.detail(launchedAt: app.launchedAt, now: now, windows: windows[app.pid] ?? 0, playing: playing.contains(app.pid),
                                     sent: Session.isUser(app.session), display: multi ? (app.display ?? d.display.slot) : nil)
            if #available(macOS 14.4, *) {
                if row.subtitle != detail { row.subtitle = detail }
            } else if row.toolTip != detail {
                row.toolTip = detail
            }
        }

        let reduceMotion = meter?.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for preview in hero?.previews ?? [] where preview.reduceMotion != reduceMotion { preview.reduceMotion = reduceMotion }
        showPage(displays: displays, sources: sources)
        // A picture that has stopped updating says so, rather than passing for live.
        if refreshTimer != nil {
            let now = ProcessInfo.processInfo.systemUptime
            for (i, preview) in (hero?.previews ?? []).enumerated() where !preview.isHidden {
                guard let slot = visibleSlots[safe: i] else { continue }
                let since = max(lastFrames[slot] ?? 0, openedAt)
                if now - since > 3.5 + Double(visibleSlots.count - 1) {
                    preview.message = preview.hasImage ? "Preview paused" : "Preview unavailable"
                }
            }
        }
    }

    /// These apps' windows on this daemon's display, front to back, from one pass over the
    /// window list: no call into the apps, so a hung app can't hold up the menu.
    private func managedWindows(of apps: [ManagedApp], on displays: [CGRect]) -> [(pid: pid_t, bounds: CGRect)] {
        guard !apps.isEmpty else { return [] }
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
        guard let source = previewSources[slot], source.active else { return [] }
        let bar = source.menuBarHeight
        let display = source.bounds
        let area = CGRect(x: display.minX, y: display.minY + bar, width: display.width, height: display.height - bar)
        guard area.width > 0, area.height > 0 else { return [] }
        let names = Dictionary(source.apps.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return managedWindows(of: source.apps, on: [area]).compactMap { window in
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
        guard !capturing, captureQueue.isEmpty else { return }   // last round still going
        captureQueue = visibleSlots.enumerated().map { (index: $0.offset, slot: $0.element) }
        captureNext()
    }

    /// One capture in flight at a time; a result for a picture that now shows another display
    /// (the page turned) is dropped.
    private func captureNext() {
        guard !capturing, !captureQueue.isEmpty, let hero else { return }
        let (index, slot) = captureQueue.removeFirst()
        guard visibleSlots[safe: index] == slot, let preview = hero.previews[safe: index],
              let source = previewSources[slot], source.active else { captureNext(); return }
        let id = source.displayID
        var executable = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &executable, UInt32(executable.count)) > 0 else {
            captureQueue.removeAll()
            return
        }
        let size = preview.bounds.size
        let scale = min(2, preview.window?.backingScaleFactor ?? item.button?.window?.backingScaleFactor ?? 2)
        let generation = thumbnailGeneration
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: String(cString: executable))
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        process.arguments = ["__menu-thumbnail", String(id), String(Double(source.menuBarHeight)),
                             String(width), String(height)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            captureNext()
            return
        }
        capturing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = output.fileHandleForReading
            let data = try? Self.readThumbnail(from: reader)
            try? reader.close()
            process.waitUntilExit()
            let status = process.terminationStatus
            let image: CGImage? = autoreleasepool {
                guard status == 0, let data, !data.isEmpty,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      properties[kCGImagePropertyPixelWidth as String] as? Int == width,
                      properties[kCGImagePropertyPixelHeight as String] as? Int == height else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.capturing = false
                guard self.refreshTimer != nil else { return }
                defer {
                    if self.captureQueue.isEmpty, generation != self.thumbnailGeneration {
                        self.refreshThumbnails()
                    } else {
                        self.captureNext()
                    }
                }
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
                self.lastFrames[slot] = ProcessInfo.processInfo.systemUptime
                preview.message = nil
                preview.setImage(image)
                preview.shownSlot = slot
                preview.regions = self.regions(slot: slot)
            }
        }
    }

    private static func readThumbnail(from reader: FileHandle) throws -> Data {
        var data = Data()
        while let chunk = try reader.read(upToCount: min(64 * 1024, thumbnailByteLimit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > thumbnailByteLimit { throw CLIError("thumbnail exceeded its maximum size") }
        }
        return data
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
            } else if let notice = sendCaution(bundleID: front.bundleIdentifier, name: front.localizedName) {
                tip += "\n\(notice) Backstage asks before sending it."
            }
        }
        send.toolTip = tip
        return send
    }

    private func closeDisplay(_ slot: Int) {
        daemon?.closeDisplayFromMenu(slot)
    }

    /// A display went (closed, or emptied and timed out): redraw an open menu's pictures.
    func displaysChanged() {
        guard refreshTimer != nil else { return }
        page = 0
        rebuild()
    }

    @objc private func recoverWindows() {
        daemon?.recoverFromMenu()
    }

    @objc private func sendFront() {
        daemon?.sendFrontWindowBackstage(from: "menu")
    }

    /// The displays as menu choices: "Display 1" (each this daemon runs, with who reserved it),
    /// then "New Display" unless every extra slot is taken. `current` is checked and disabled.
    private func displayChoices(current: Int?, action: Selector, payload: (String) -> Any) -> [NSMenuItem] {
        guard let d = daemon else { return [] }
        let apps = d.registry.filter { $0.matchesProcess }
        var items: [NSMenuItem] = []
        for shown in d.allDisplays {
            let n = apps.filter { ($0.display ?? d.display.slot) == shown.slot }.count
            var title = "Display \(shown.slot)"
            if let r = d.reservations[shown.slot], r.until > Date().timeIntervalSince1970 {
                title += Session.isUser(r.session) ? " (yours)" : " (reserved by an agent)"
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = payload(String(shown.slot))
            item.toolTip = n == 1 ? "1 app" : "\(n) apps"
            if shown.slot == current { item.state = .on; item.isEnabled = false }
            items.append(item)
        }
        items.append(.separator())
        let new = NSMenuItem(title: "New Display", action: action, keyEquivalent: "")
        new.target = self
        new.representedObject = payload("new")
        new.isEnabled = d.extraSlots.contains { d.extras[$0] == nil }
        new.toolTip = new.isEnabled ? "A fresh hidden display, kept for you; it goes away 30 minutes after its last app leaves"
            : "Every display backstage may add is in use"
        items.append(new)
        return items
    }

    /// An app's Move to ▸: put it on another hidden display (any session's app: your choice wins
    /// over an agent's reservation).
    private func moveItem(for app: ManagedApp, name: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for choice in displayChoices(current: app.display ?? daemon?.display.slot, action: #selector(moveApp(_:)),
                                     payload: { [app, $0] as [Any] }) { sub.addItem(choice) }
        item.submenu = sub
        item.toolTip = "Moves \(name) to another hidden display. Agents still reach it by its PID; coordinates follow it."
        return item
    }

    /// Send Front Window To ▸: like Send Front Window Backstage, onto a display you pick, e.g. a
    /// display of your own while agents work on display 1.
    private func sendToItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Send Front Window To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for choice in displayChoices(current: nil, action: #selector(sendFrontTo(_:)), payload: { $0 }) { sub.addItem(choice) }
        item.submenu = sub
        let plain = sendItem()
        item.isEnabled = plain.isEnabled
        item.toolTip = plain.isEnabled ? "Sends the frontmost app to the hidden display you pick. Later sends follow it there."
            : plain.toolTip
        return item
    }

    @objc private func sendFrontTo(_ sender: NSMenuItem) {
        guard let want = sender.representedObject as? String else { return }
        daemon?.sendFrontWindowBackstage(from: "menu", to: want)
    }

    @objc private func moveApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], pair.count == 2, let selected = pair[0] as? ManagedApp, let want = pair[1] as? String,
              let record = daemon?.registry.first(where: { $0.pid == selected.pid && $0.processStart == selected.processStart }) else { return }
        if let why = daemon?.moveApp(record, to: want) {
            daemon?.log("menu move failed: \(why)")
            sendCue(text: "Can't move \(record.name): \(why)", success: false)
        }
    }

    @objc private func toggleKeep() {
        guard let d = daemon else { return }
        do { try Settings.update { $0.keepInMenuBar = !$0.keep } }
        catch { d.log("couldn't save settings: \(error)"); return }
        d.applySettings()
    }

    @objc private func showApp(_ sender: NSMenuItem) {
        guard let rec = currentApp(sender) else { NSSound.beep(); return }
        do { try handOver(rec, wait: false) } catch { NSSound.beep(); daemon?.log("menu show failed (busy launch/stop?): \(error)") }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let record = currentApp(sender) else { return }
        daemon?.quitFromMenu(record, force: false)
    }

    @objc private func forceQuitApp(_ sender: NSMenuItem) {
        guard let record = currentApp(sender) else { return }
        daemon?.quitFromMenu(record, force: true)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Paths.dir)
    }

    @objc private func stopAll() {
        guard let d = daemon else { return }
        // With Auto-Hide When Idle off, the apps go but Backstage stays.
        if d.keepActive { d.quitAllApps() } else { d.shutdown(reason: "stopped from the menu bar") }
    }
}

/// Internal child entry point. Exit under the locks even if the asynchronous capture times out.
func runMenuThumbnail(_ args: Args) throws {
    guard let id = args.pos(0).flatMap(CGDirectDisplayID.init),
          let menuBar = args.pos(1).flatMap(Double.init), menuBar.isFinite, menuBar >= 0,
          let width = args.pos(2).flatMap(Int.init), (1...Int(StatusMenu.thumbWidth * 2)).contains(width),
          let height = args.pos(3).flatMap(Int.init), (1...Int(MenuHeroView.maxPreviewHeight * 2)).contains(height) else {
        throw CLIError("invalid thumbnail dimensions")
    }
    func parentDisplay() -> (daemon: DaemonInfo, slot: Int)? {
        guard let daemon = liveDaemon(), daemon.pid == getppid(), daemon.stopping != true else { return nil }
        let slot = id == daemon.displayID ? daemon.primarySlot : daemon.displays?.first { $0.displayID == id }?.slot
        guard let slot, displaySlots.contains(slot), isOurDisplay(id), CGDisplayIsActive(id) != 0,
              CGDisplaySerialNumber(id) == displaySerial(slot: slot) else { return nil }
        return (daemon, slot)
    }
    guard parentDisplay() != nil else {
        throw CLIError("thumbnail capture must target the parent daemon's live backstage display")
    }
    guard let lock = try? StateLock("capture.lock", nonblocking: true),
          let userLock = UserLock("capture.lock", nonblocking: true) else { return }
    withExtendedLifetime((lock, userLock)) {
        guard let image = try? runAsync(timeout: captureAttemptTimeout, {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let (daemon, slot) = parentDisplay(),
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CLIError("display unavailable")
            }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > menuBar else { throw CLIError("display unavailable") }
            func registrations() throws -> [pid_t: CaptureRegistration] {
                let apps = try AppStore.read { ($0.display ?? daemon.primarySlot) == slot }
                return CaptureRegistration.snapshot(apps, primary: daemon.primarySlot)
            }
            let before = try registrations()
            let windows = content.windows.filter {
                $0.frame.intersects(bounds) && $0.owningApplication.map { before[$0.processID] != nil } == true
            }
            if windows.isEmpty {
                // An empty including filter does not represent an empty frame on every macOS release.
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let image = context.makeImage() else { throw CLIError("cannot create empty preview") }
                return image
            }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: menuBar, width: bounds.width, height: bounds.height - menuBar)
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            if #available(macOS 14.2, *) { config.includeChildWindows = false }
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, including: windows), configuration: config
            )
            guard let (current, currentSlot) = parentDisplay(), slot == currentSlot,
                  current.startedAt == daemon.startedAt, current.processStart == daemon.processStart,
                  CGDisplayBounds(id) == bounds, try registrations() == before else {
                throw CLIError("preview source changed during capture")
            }
            return image
        }), let data = CFDataCreateMutable(nil, 0),
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), CFDataGetLength(data) <= StatusMenu.thumbnailByteLimit else { exit(1) }
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
        preview.onClose = shown.visible[i] == 1 ? nil : {}
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
            "previews": view.previews.map { ["y": $0.frame.minY, "height": $0.frame.height, "hidden": $0.isHidden, "closable": $0.closable] },
            "pager": view.pagerFrames ?? NSNull()]
}
