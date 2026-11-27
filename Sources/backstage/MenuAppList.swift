import AppKit
import QuartzCore

// The menu's list of apps: a heading per session (with its app count) and a two-line row per app,
// in a scroll view of bounded height. However many agents and apps there are, the menu keeps its
// size: the picture above and the actions below stay in view, and the list scrolls in its own
// space, with a thin overlay scroller and soft edges where more is hidden.
//
// Rows behave like menu items with submenus: pointing at one highlights it (and picks the app's
// windows out in the picture), and after a moment its actions open beside it, as a submenu would;
// moving to another row, or back into the menu, closes them. A click opens them at once.

final class MenuAppListView: NSView {
    enum Entry {
        case heading(String, count: Int)
        case app(pid: pid_t, name: String, icon: NSImage?, detail: String, actions: NSMenu)
    }

    static let headingHeight: CGFloat = 26
    static let rowHeight: CGFloat = 40
    static let inset: CGFloat = 6              // space above the first and below the last entry
    static let fade: CGFloat = 14              // soft edge where more of the list is hidden
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var rowViews: [pid_t: MenuAppRowView] = [:]
    private let maxHeight: CGFloat
    private let width: CGFloat
    private let mask = CAGradientLayer()
    /// The app under the pointer (nil when none), for the picture's highlight.
    var onHover: ((pid_t?) -> Void)?

    init(width: CGFloat, maxHeight: CGFloat) {
        self.width = width
        self.maxHeight = maxHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = ThinScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        scroll.wantsLayer = true
        addSubview(scroll)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Apps on the hidden displays")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func setEntries(_ entries: [Entry]) {
        document.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        var y = Self.inset
        for entry in entries {
            switch entry {
            case let .heading(text, count):
                // The session's app count as a badge at the right, lined up with the rows' arrows.
                let badge = MenuCountBadge(count: count)
                badge.frame.origin = NSPoint(x: width - MenuAppRowView.trailing - badge.frame.width,
                                             y: y + (Self.headingHeight - badge.frame.height) / 2 + 2)
                document.addSubview(badge)
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingMiddle
                label.frame = NSRect(x: MenuAppRowView.leading, y: y + 7, width: badge.frame.minX - 10 - MenuAppRowView.leading, height: 16)
                label.setAccessibilityRole(.staticText)
                label.setAccessibilityLabel("\(text), \(count) app\(count == 1 ? "" : "s")")
                document.addSubview(label)
                y += Self.headingHeight
            case let .app(pid, name, icon, detail, actions):
                let row = MenuAppRowView(frame: NSRect(x: 0, y: y, width: width, height: Self.rowHeight),
                                         name: name, icon: icon, detail: detail, actions: actions)
                row.list = self
                document.addSubview(row)
                rowViews[pid] = row
                row.pid = pid
                y += Self.rowHeight
            }
        }
        y += Self.inset
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        frame = NSRect(x: 0, y: 0, width: width, height: min(y, maxHeight))
        scroll.frame = bounds
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        scrolled()
    }

    func setDetail(_ detail: String, for pid: pid_t) {
        rowViews[pid]?.detail = detail
    }

    /// The menu closed: nothing stays highlighted or pending.
    func resetHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        rowViews.values.forEach { $0.highlighted = false }
    }

    // MARK: edges

    /// Fade the top edge only when the list is scrolled down, the bottom only when more is below.
    @objc private func scrolled() {
        let height = scroll.bounds.height
        guard document.frame.height > height + 1, height > 0, let layer = scroll.layer else {
            scroll.layer?.mask = nil
            return
        }
        let offset = scroll.contentView.bounds.minY
        let top = offset > 1 ? Self.fade / height : 0
        let bottom = offset < document.frame.height - height - 1 ? Self.fade / height : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layer.bounds
        // Layer coordinates run bottom-up: 0 is the bottom edge.
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, NSNumber(value: Double(bottom)), NSNumber(value: Double(1 - top)), 1]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = mask
        CATransaction.commit()
    }

    // MARK: rows as submenus

    private var hoverTimer: Timer?
    private var openRow: MenuAppRowView?

    func rowEntered(_ row: MenuAppRowView) {
        for other in rowViews.values where other !== row { other.highlighted = false }
        row.highlighted = true
        onHover?(row.pid)
        guard openRow == nil else { return }
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self, weak row] _ in
            guard let self, let row, row.highlighted else { return }
            self.showActions(of: row)
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func rowExited(_ row: MenuAppRowView) {
        guard openRow !== row else { return }
        row.highlighted = false
        onHover?(nil)
    }

    /// Opens a row's actions beside it, like a submenu, and keeps them open while the pointer is
    /// on the row or the actions (or outside the menu altogether); pointing at anything else in
    /// the menu closes them, and opens the next row's if that's where the pointer went.
    func showActions(of row: MenuAppRowView) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard openRow == nil, let window = row.window else { return }
        openRow = row
        row.highlighted = true
        let anchorInWindow = row.convert(NSPoint(x: row.bounds.width, y: row.bounds.height + 5), to: nil)
        let anchor = window.convertPoint(toScreen: anchorInWindow)
        var outsideSince: Double?
        let watch = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak row] _ in
            guard self != nil, let row, let window = row.window else { return }
            let mouse = NSEvent.mouseLocation
            let rowRect = window.convertToScreen(row.convert(row.visibleRect, to: nil))
            let size = row.actions.size
            let actionsRect = NSRect(x: anchor.x - 8, y: anchor.y - size.height - 8, width: size.width + 16, height: size.height + 16)
            let onMenu = window.frame.contains(mouse)
            if rowRect.contains(mouse) || actionsRect.contains(mouse) || !onMenu {
                outsideSince = nil
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - (outsideSince ?? now) >= 0.15 { row.actions.cancelTracking() }
            if outsideSince == nil { outsideSince = now }
        }
        RunLoop.main.add(watch, forMode: .common)
        row.actions.popUp(positioning: nil, at: row.convert(anchorInWindow, from: nil), in: row)
        watch.invalidate()
        openRow = nil
        // Closed: hand over to whatever row the pointer is on now (its own hover opens it).
        let mouse = NSEvent.mouseLocation
        let next = rowViews.values.first { other in
            guard let w = other.window else { return false }
            return w.convertToScreen(other.convert(other.visibleRect, to: nil)).contains(mouse)
        }
        for other in rowViews.values where other !== next { other.highlighted = false }
        if let next, next !== row { rowEntered(next) } else if next == nil { onHover?(nil) }
    }
}

/// An overlay scroller like a menu's: a thin knob, no track.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 10 }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 0, dy: 2)
        let bar = NSRect(x: knob.maxX - 3 - 5, y: knob.minY, width: 5, height: knob.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

/// A small rounded count, like a menu item's badge.
final class MenuCountBadge: NSView {
    private let text: NSAttributedString
    init(count: Int) {
        text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        super.init(frame: NSRect(x: 0, y: 0, width: max(22, ceil(size.width) + 14), height: 17))
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class MenuAppRowView: NSView {
    static let leading: CGFloat = 14
    /// Space right of the arrow: room for the overlay scroller, so it never covers the arrow.
    static let trailing: CGFloat = 20
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let iconView = NSImageView()
    private let chevron = NSImageView()
    let actions: NSMenu
    weak var list: MenuAppListView?
    var pid: pid_t = 0
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true; updateColors() } } }
    var detail: String {
        get { detailLabel.stringValue }
        set { if detailLabel.stringValue != newValue { detailLabel.stringValue = newValue; setAccessibilityValue(newValue) } }
    }

    init(frame: NSRect, name: String, icon: NSImage?, detail: String, actions: NSMenu) {
        nameLabel = NSTextField(labelWithString: name)
        detailLabel = NSTextField(labelWithString: detail)
        self.actions = actions
        super.init(frame: frame)
        let textX = Self.leading + 26 + 10
        let arrowX = frame.width - Self.trailing - 8
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: Self.leading, y: (frame.height - 26) / 2, width: 26, height: 26)
        addSubview(iconView)
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: textX, y: frame.height / 2 - 1, width: arrowX - 10 - textX, height: 17)
        addSubview(nameLabel)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: textX, y: frame.height / 2 - 16, width: arrowX - 10 - textX, height: 15)
        addSubview(detailLabel)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.frame = NSRect(x: arrowX, y: (frame.height - 14) / 2, width: 8, height: 14)
        addSubview(chevron)
        updateColors()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel(name)
        setAccessibilityValue(detail)
        setAccessibilityHelp("Shows actions for \(name)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func updateColors() {
        nameLabel.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        detailLabel.textColor = highlighted ? .selectedMenuItemTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        chevron.contentTintColor = highlighted ? .selectedMenuItemTextColor : .tertiaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        // Inset like a menu's selection, and clear of the scroller's lane.
        NSBezierPath(roundedRect: NSRect(x: 5, y: 1, width: bounds.width - 5 - 12, height: bounds.height - 2), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseEntered(with event: NSEvent) { list?.rowEntered(self) }
    override func mouseExited(with event: NSEvent) { list?.rowExited(self) }
    override func mouseUp(with event: NSEvent) { list?.showActions(of: self) }
    override func accessibilityPerformPress() -> Bool { list?.showActions(of: self); return true }
}
