// Fixture app for backstage's end-to-end test. Logs everything it receives to TESTAPP_LOG.
// Env: TESTAPP_ACTIVATE=1 -> calls NSApp.activate() 1s after launch (rude app)
//      TESTAPP_POPUP=1    -> opens a second window 2s after launch (tests the new-window guard)
//      TESTAPP_MARKER=X   -> prints "fixture marker X" to stdout (tells instances apart in logs)
//      TESTAPP_PAD=red|green -> pad color (tells instances apart in screenshots; default blue)
//      TESTAPP_OVERLAYS=1 -> a pad-colored swatch in the pad's context menu, and Actions > Show Sheet /
//                            Show Popover / Close Overlays, whose contents are pad-colored swatches
//      TESTAPP_SPOT="X,Y [X,Y…]" -> Actions > Move To Spot 1, 2…: moves the window's top-left to that
//                            point on its screen and orders it in front of other apps' windows (forces overlaps)
//      TESTAPP_SLOW_LAUNCH=S -> blocks the main thread for S seconds before creating the window
//      TESTAPP_ACCESSORY=1 -> .accessory activation policy: no Dock icon (load runs with many instances)
import Cocoa

func log(_ s: String) {
    guard let logPath = ProcessInfo.processInfo.environment["TESTAPP_LOG"] else { exit(2) }
    if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
    let h = FileHandle(forWritingAtPath: logPath)!
    h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile()
}

func padColor() -> NSColor {
    switch ProcessInfo.processInfo.environment["TESTAPP_PAD"] {
    case "red": return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    case "green": return NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    default: return .systemBlue
    }
}
let overlays = ProcessInfo.processInfo.environment["TESTAPP_OVERLAYS"] == "1"

/// A solid block of the pad color, for finding menus, sheets and popovers in screenshots.
final class Swatch: NSView {
    override func draw(_ r: NSRect) { padColor().setFill(); bounds.fill() }
}

/// Custom-drawn view with no accessibility children: only raw mouse events can hit it.
final class Pad: NSView {
    var clicks = 0
    override func draw(_ r: NSRect) {
        padColor().setFill(); bounds.fill()
        ("pad clicks: \(clicks)" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16)])
    }
    override func mouseDown(with e: NSEvent) {
        clicks += 1
        let p = convert(e.locationInWindow, from: nil)
        log("pad click \(clicks) at \(Int(p.x)),\(Int(p.y)) count=\(e.clickCount)")
        needsDisplay = true
    }
    override func scrollWheel(with e: NSEvent) { log("pad scroll dy=\(e.scrollingDeltaY)") }
    var dragged = 0
    override func mouseDragged(with e: NSEvent) { dragged += 1 }
    override func mouseUp(with e: NSEvent) {
        if dragged > 0 { let p = convert(e.locationInWindow, from: nil); log("pad drag steps=\(dragged) end=\(Int(p.x)),\(Int(p.y))"); dragged = 0 }
    }
    override func rightMouseDown(with e: NSEvent) {
        log("pad right click")
        let m = NSMenu(); m.addItem(withTitle: "Pad Option", action: nil, keyEquivalent: "")
        if overlays { let swatch = NSMenuItem(); swatch.view = Swatch(frame: NSRect(x: 0, y: 0, width: 200, height: 60)); m.addItem(swatch) }
        NSMenu.popUpContextMenu(m, with: e, for: self)   // blocks until the menu closes
        log("context menu closed")
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { let p = convert(e.locationInWindow, from: nil); log("pad hover \(Int(p.x)),\(Int(p.y))") }
}

final class D: NSObject, NSApplicationDelegate {
    var w: NSWindow!; var label: NSTextField!; var n = 0
    func applicationDidFinishLaunching(_ a: Notification) {
        if let slow = Double(ProcessInfo.processInfo.environment["TESTAPP_SLOW_LAUNCH"] ?? "") { log("slow launch \(slow)s"); Thread.sleep(forTimeInterval: slow) }
        w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "BackstageTestApp"
        let b = NSButton(title: "Increment", target: self, action: #selector(inc)); button = b; b.frame = NSRect(x: 20, y: 220, width: 120, height: 30)
        label = NSTextField(labelWithString: "count: 0"); label.frame = NSRect(x: 160, y: 225, width: 150, height: 24); label.font = .systemFont(ofSize: 20)
        let tf = NSTextField(frame: NSRect(x: 20, y: 170, width: 300, height: 26)); tf.placeholderString = "type here"
        let pad = Pad(frame: NSRect(x: 20, y: 20, width: 380, height: 130))
        for v in [b, label!, tf, pad] as [NSView] { w.contentView!.addSubview(v) }
        w.makeKeyAndOrderFront(nil); w.makeFirstResponder(tf)
        log("launched active=\(NSApp.isActive)")
        print("fixture stdout hello")
        if let marker = ProcessInfo.processInfo.environment["TESTAPP_MARKER"] { print("fixture marker \(marker)") }
        fflush(stdout)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { e in log("monitor type=\(e.type.rawValue) clicks=\(e.clickCount) win=\(e.windowNumber)"); return e }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in log("became active!") }
        NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: tf, queue: nil) { _ in log("text=\(tf.stringValue)") }
        let env = ProcessInfo.processInfo.environment
        if env["TESTAPP_ACTIVATE"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { log("calling activate"); NSApp.activate(ignoringOtherApps: true) } }
        if env["TESTAPP_POPUP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let p = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 300, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                p.title = "Popup"; p.isReleasedWhenClosed = false
                if env["TESTAPP_POPUP_CENTER"] == "1" { p.center() }
                p.makeKeyAndOrderFront(nil); log("popup opened")
                self.popup = p
            }
        }
    }
    var popup: NSWindow?
    @objc func inc() { n += 1; label.stringValue = "count: \(n)"; log("inc \(n)") }

    var button: NSButton!, sheet: NSWindow?, popover: NSPopover?
    @objc func showSheet() {
        let s = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        s.contentView = Swatch(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        w.beginSheet(s) { _ in }
        sheet = s; log("sheet opened")
    }
    @objc func showPopover() {
        let p = NSPopover(); p.behavior = .applicationDefined
        let content = NSViewController(); content.view = Swatch(frame: NSRect(x: 0, y: 0, width: 240, height: 90))
        p.contentViewController = content
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover = p; log("popover opened")
    }
    @objc func closeOverlays() {
        if let s = sheet { w.endSheet(s); sheet = nil }
        popover?.close(); popover = nil
        log("overlays closed")
    }
    @objc func moveToSpot(_ item: NSMenuItem) {
        guard let spot = item.representedObject as? NSPoint, let screen = w.screen?.frame else { return }
        w.setFrameTopLeftPoint(NSPoint(x: screen.minX + spot.x, y: screen.maxY - spot.y))
        w.orderFrontRegardless()
        log("moved to spot \(Int(spot.x)),\(Int(spot.y))")
    }
}

// The executable-wrapper fixture registers with AppKit without creating any windows.
if ProcessInfo.processInfo.environment["TESTAPP_BARE"] == "1" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    log("pid=\(getpid())")
    log("argument=\(CommandLine.arguments.last ?? "")")
    log("cwd=\(FileManager.default.currentDirectoryPath)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    app.run()
    exit(0)
}

let app = NSApplication.shared; let d = D(); app.delegate = d
app.setActivationPolicy(ProcessInfo.processInfo.environment["TESTAPP_ACCESSORY"] == "1" ? .accessory : .regular)
let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
let actItem = NSMenuItem(); menu.addItem(actItem)
let actMenu = NSMenu(title: "Actions"); actMenu.addItem(withTitle: "Increment", action: #selector(D.inc), keyEquivalent: "i").target = d; actItem.submenu = actMenu
if overlays {
    actMenu.addItem(withTitle: "Show Sheet", action: #selector(D.showSheet), keyEquivalent: "").target = d
    actMenu.addItem(withTitle: "Show Popover", action: #selector(D.showPopover), keyEquivalent: "").target = d
    actMenu.addItem(withTitle: "Close Overlays", action: #selector(D.closeOverlays), keyEquivalent: "").target = d
}
for (i, spot) in (ProcessInfo.processInfo.environment["TESTAPP_SPOT"] ?? "").split(separator: " ").enumerated() {
    let xy = spot.split(separator: ",").compactMap { Double($0) }
    guard xy.count == 2 else { continue }
    let item = actMenu.addItem(withTitle: "Move To Spot \(i + 1)", action: #selector(D.moveToSpot(_:)), keyEquivalent: "")
    item.target = d; item.representedObject = NSPoint(x: xy[0], y: xy[1])
}
let editItem = NSMenuItem(); menu.addItem(editItem)
let editMenu = NSMenu(title: "Edit"); editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); editItem.submenu = editMenu
app.mainMenu = menu
app.run()
