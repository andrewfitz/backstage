import AppKit
import QuartzCore

/// The top of the menu: what Backstage is doing, in a sentence, and a live picture of the hidden
/// display. One view, so the text and the picture share the menu's grid: the text starts where
/// menu item titles start, and the picture sits just outside it, like the selection highlight.
/// Nothing here knows about the daemon; StatusMenu feeds it.
final class MenuHeroView: NSView {
    /// Where NSMenu starts item titles and images.
    static let textInset: CGFloat = 16
    static let previewInset: CGFloat = 12
    /// A very tall display (BACKSTAGE_WIDTH/HEIGHT) gets a narrower, centred picture, not a taller menu.
    static let maxPreviewHeight: CGFloat = 240

    /// The menu's width for a picture this wide.
    static func width(previewWidth: CGFloat) -> CGFloat { previewWidth + previewInset * 2 }

    /// Nil when there's no display to show.
    let preview: DisplayPreviewView?

    /// Kept for callers; the menu no longer shows a status line (the picture and rows say it).
    var status: String = ""

    override var isFlipped: Bool { true }

    /// `aspect` is the previewed area's width over its height; nil for no picture.
    init(previewWidth: CGFloat, aspect: CGFloat?) {
        let width = Self.width(previewWidth: previewWidth)
        var previewSize = CGSize.zero
        if let aspect, aspect.isFinite, aspect > 0 {
            let height = max(1, min((previewWidth / aspect).rounded(), Self.maxPreviewHeight))
            previewSize = CGSize(width: max(1, min(previewWidth, (height * aspect).rounded())), height: height)
            preview = DisplayPreviewView(frame: NSRect(origin: .zero, size: previewSize))
        } else {
            preview = nil
        }
        // The picture leads the menu: the same inset above it as on its sides.
        let previewTop = Self.previewInset - 6
        let height = preview == nil ? 0 : previewTop + previewSize.height + 5
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]
        if let preview {
            preview.frame.origin = CGPoint(x: ((width - previewSize.width) / 2).rounded(), y: previewTop)
            preview.autoresizingMask = [.minXMargin, .maxXMargin]   // stays centred if the menu gets wider
            addSubview(preview)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A live picture of the agent display: rounded like the menu's own highlight, a hairline edge so
/// light content doesn't bleed into a light menu, a quiet placeholder until the first frame, and
/// an outline around one app's windows when its row (or the window itself) is pointed at.
final class DisplayPreviewView: NSView {
    /// One managed window, in fractions of the picture (origin top left).
    struct Region: Equatable {
        let pid: pid_t
        let name: String
        let rect: CGRect
    }

    static let cornerRadius: CGFloat = 8

    /// Windows in the picture, front to back.
    var regions: [Region] = [] {
        didSet { if regions != oldValue { hovered = hoveredRegion(); updateOverlay(); updateAccessibility() } }
    }
    /// Apps whose rows are highlighted in the menu.
    var highlighted: Set<pid_t> = [] {
        didSet { if highlighted != oldValue { updateOverlay() } }
    }
    /// Shown instead of the picture (none yet), or over a darkened one (it stopped updating).
    var message: String? {
        didSet { if message != oldValue { updateState() } }
    }
    /// The picture is left over from the last time the menu was open: shown faded until a new
    /// frame arrives, so it's there at once without passing for live.
    var isStale = false {
        didSet { if isStale != oldValue { updateState() } }
    }
    private(set) var hasImage = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let canvas = NSView()
    private let imageLayer = CALayer()
    private let scrimLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let placeholder = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let nameChip = Chip()
    private var pointer: CGPoint?
    private var hovered: Region?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        // The picture and its overlays are plain layers in a layer-hosting view: a new frame or a
        // highlight changes layer properties, and AppKit draws nothing.
        canvas.layer = CALayer()
        canvas.wantsLayer = true
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.minificationFilter = .trilinear
        imageLayer.masksToBounds = true
        // Dark in both appearances: these sit on the picture, not on the menu.
        scrimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        scrimLayer.isHidden = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.36).cgColor
        dimLayer.opacity = 0
        outlineLayer.fillColor = nil
        outlineLayer.lineWidth = 1.5
        outlineLayer.opacity = 0
        for l in [imageLayer, scrimLayer, dimLayer, outlineLayer] {
            l.frame = bounds
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull()]
            canvas.layer?.addSublayer(l)
        }

        placeholder.image = NSImage(systemSymbolName: "rectangle.on.rectangle.dashed", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        placeholder.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.imageScaling = .scaleNone
        addSubview(placeholder)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.isHidden = true
        addSubview(messageLabel)
        nameChip.isHidden = true
        addSubview(nameChip)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview of the hidden display")
        updateColors()
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A new frame. The first one appears at once; later ones cross-fade briefly, unless Reduce
    /// Motion is on.
    func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasImage, !reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            imageLayer.add(fade, forKey: "frame")
        }
        imageLayer.contents = image
        CATransaction.commit()
        hasImage = true
        isStale = false
        updateState()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [imageLayer, scrimLayer, dimLayer, outlineLayer] { l.frame = bounds }
        CATransaction.commit()
        let icon = placeholder.image?.size ?? .zero
        let hasText = !messageLabel.isHidden
        let block = icon.height + (hasText ? 8 + 15 : 0)
        placeholder.frame = NSRect(x: ((bounds.width - icon.width) / 2).rounded(), y: ((bounds.height - block) / 2).rounded(),
                                   width: icon.width, height: icon.height)
        let textY = hasImage ? ((bounds.height - 15) / 2).rounded() : placeholder.frame.maxY + 8
        messageLabel.frame = NSRect(x: 12, y: textY, width: bounds.width - 24, height: 15)
        layoutNameChip()
        updateOverlay()
    }

    private func layoutNameChip() {
        nameChip.sizeToFit()
        nameChip.frame.size.width = min(nameChip.frame.width, bounds.width - 12)
        nameChip.frame.origin = CGPoint(x: 6, y: bounds.maxY - nameChip.frame.height - 6)
    }

    // MARK: appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateColors()
    }

    /// Layer colours don't follow the appearance by themselves: resolve them for the current one.
    private func updateColors() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            outlineLayer.strokeColor = NSColor.controlAccentColor.cgColor
        }
        layer?.borderWidth = 1 / scale
        imageLayer.contentsScale = scale
    }

    private func updateState() {
        let text = message ?? ""
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        placeholder.isHidden = hasImage
        // Over a picture that stopped updating: darken it, and say so in white.
        messageLabel.textColor = hasImage ? .white : .secondaryLabelColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.2)
        scrimLayer.isHidden = !(hasImage && !text.isEmpty)
        imageLayer.opacity = isStale ? 0.45 : 1
        CATransaction.commit()
        needsLayout = true
        updateOverlay()
        updateAccessibility()
    }

    // MARK: which window is which

    /// The app (or the single window under the pointer) to pick out, and the rest dimmed.
    private func updateOverlay() {
        let live = hasImage && !isStale
        let active: [Region] = hovered.map { [$0] } ?? regions.filter { highlighted.contains($0.pid) }
        let show = live && !active.isEmpty
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.12)
        if show {
            let dim = CGMutablePath()
            dim.addRect(bounds)
            let outline = CGMutablePath()
            for region in active {
                let r = rect(of: region)
                let rounded = CGPath(roundedRect: r, cornerWidth: min(3, r.width / 2), cornerHeight: min(3, r.height / 2), transform: nil)
                dim.addPath(rounded)
                outline.addPath(rounded)
            }
            dimLayer.path = dim
            outlineLayer.path = outline
        }
        dimLayer.opacity = show ? 1 : 0
        outlineLayer.opacity = show ? 1 : 0
        CATransaction.commit()

        let name = live ? hovered?.name : nil
        if let name, nameChip.text != name { nameChip.text = name; layoutNameChip() }
        nameChip.isHidden = name == nil
    }

    /// A region in the canvas's layer coordinates (origin bottom left).
    private func rect(of region: Region) -> CGRect {
        CGRect(x: region.rect.minX * bounds.width, y: (1 - region.rect.maxY) * bounds.height,
               width: region.rect.width * bounds.width, height: region.rect.height * bounds.height)
            .insetBy(dx: 0.75, dy: 0.75)
    }

    private func hoveredRegion() -> Region? {
        guard let p = pointer, bounds.width > 0, bounds.height > 0 else { return nil }
        let unit = CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
        return regions.first { $0.rect.contains(unit) }
    }

    private func pointerMoved(_ event: NSEvent?) {
        pointer = event.map { convert($0.locationInWindow, from: nil) }
        let now = hoveredRegion()
        guard now != hovered else { return }
        hovered = now
        updateOverlay()
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { pointerMoved(nil) }

    /// The menu closed: forget where the pointer was.
    func resetPointer() { pointerMoved(nil) }

    // MARK: accessibility

    private func updateAccessibility() {
        var names: [String] = []
        for region in regions where !names.contains(region.name) { names.append(region.name) }
        setAccessibilityValue(!hasImage ? (message ?? "Loading") : names.isEmpty ? "No windows" : "Showing " + names.joined(separator: ", "))
    }

    /// A small dark capsule over the picture: the name of the app under the pointer.
    private final class Chip: NSView {
        private let label = NSTextField(labelWithString: "")
        var text: String {
            get { label.stringValue }
            set { label.stringValue = newValue; needsLayout = true }
        }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
            layer?.cornerRadius = 5
            layer?.cornerCurve = .continuous
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func sizeToFit() {
            label.sizeToFit()
            frame.size = CGSize(width: ceil(label.frame.width) + 8, height: 20)
        }

        override func layout() {
            super.layout()
            let height = label.frame.height
            label.frame = NSRect(x: 4, y: ((bounds.height - height) / 2).rounded(.down), width: bounds.width - 8, height: height)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The project's home page, linked from the menu's footer.
let backstageRepoURL = URL(string: "https://github.com/andrewfitz/backstage")!

/// Small, quiet footer: "Backstage v1.2.0 · GitHub", with GitHub as a link.
final class MenuFooterView: NSView {
    private let onLink: () -> Void
    private let label = NSTextField(labelWithString: "")
    private let link = NSButton(title: "GitHub", target: nil, action: nil)

    init(width: CGFloat, onLink: @escaping () -> Void) {
        self.onLink = onLink
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        autoresizingMask = [.width]
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        label.font = font
        label.textColor = .tertiaryLabelColor
        label.stringValue = "Backstage v\(backstageVersion)  ·"
        label.sizeToFit()
        label.frame.origin = CGPoint(x: MenuHeroView.textInset - 2, y: ((bounds.height - label.frame.height) / 2).rounded())
        addSubview(label)

        link.isBordered = false
        link.setButtonType(.momentaryChange)
        link.attributedTitle = NSAttributedString(string: "GitHub", attributes: [
            .font: font, .foregroundColor: NSColor.linkColor,
        ])
        link.target = self
        link.action = #selector(open)
        link.sizeToFit()
        link.frame.origin = CGPoint(x: label.frame.maxX + 2, y: ((bounds.height - link.frame.height) / 2).rounded())
        link.toolTip = backstageRepoURL.absoluteString
        link.setAccessibilityLabel("Backstage on GitHub")
        addSubview(link)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() { addCursorRect(link.frame, cursor: .pointingHand) }

    @objc private func open() { onLink() }
}
