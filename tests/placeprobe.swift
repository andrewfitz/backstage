// Window-placement fixture for placement.sh. Every window is fully transparent (alphaValue 0), so
// nothing shows even where placement fails.
//
// At start it shows windows by every AppKit route at a spot on the main display and reports,
// right after each call, whether the window is already on a backstage display ("ok"/"FAIL"), then
// "failures: N". It keeps running; each SIGUSR1 opens one more window ("signal N: backstage" or
// "signal N: elsewhere", then its frame). A window left elsewhere is hidden at once.
//
// Built two ways: linked into an executable (AppKit loads at launch), and as a library a plain C
// host loads with dlopen (AppKit arrives late, the way xctest loads a test bundle).
import AppKit

private func onBackstage(_ f: NSRect) -> Bool {
    let h = CGDisplayBounds(CGMainDisplayID()).height
    let g = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var n: UInt32 = 0
    CGGetActiveDisplayList(32, &ids, &n)
    return ids.prefix(Int(n)).contains { CGDisplayVendorNumber($0) == 0xB57A && CGDisplayBounds($0).contains(g) }
}

private var windows: [NSWindow] = []
private var signalSource: DispatchSourceSignal?

private func say(_ s: String) {
    print(s)
    fflush(stdout)
}

private func make(_ cls: NSWindow.Type = NSWindow.self, style: NSWindow.StyleMask = [.titled, .closable, .resizable]) -> NSWindow {
    let w = cls.init(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: style, backing: .buffered, defer: false)
    w.alphaValue = 0
    w.isReleasedWhenClosed = false
    windows.append(w)
    return w
}

@_cdecl("bs_probe") public func runProbe() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var failures = 0
    func check(_ name: String, _ w: NSWindow) {
        let ok = onBackstage(w.frame)
        if !ok { failures += 1; w.orderOut(nil) }
        say("\(ok ? "ok  " : "FAIL") \(name): \(w.frame)")
    }
    var w = make(); w.orderFront(nil); check("orderFront", w)
    w = make(); w.makeKeyAndOrderFront(nil); check("makeKeyAndOrderFront", w)
    w = make(); w.orderFrontRegardless(); check("orderFrontRegardless", w)
    w = make(); w.orderBack(nil); check("orderBack", w)
    w = make(); w.setIsVisible(true); check("setIsVisible", w)
    w = make(); w.order(.above, relativeTo: 0); check("orderWindow", w)
    w = make(NSPanel.self, style: [.titled, .utilityWindow]); w.orderFront(nil); check("NSPanel", w)
    w = make(style: [.borderless]); w.orderFront(nil); check("borderless", w)
    w = make(); w.center(); w.makeKeyAndOrderFront(nil); check("center then show", w)
    let controller = NSWindowController(window: make()); controller.showWindow(nil); check("showWindow", controller.window!)
    let again = windows[0]; again.orderOut(nil); again.orderFront(nil); check("hidden and shown again", again)
    let sheet = make(); windows[1].beginSheet(sheet) { _ in }; check("sheet", sheet)
    say("failures: \(failures)")

    signal(SIGUSR1, SIG_IGN)
    var count = 0
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler {
        // Signals that arrive before the handler runs are merged: one window for each.
        for _ in 0..<max(1, Int(source.data)) {
            count += 1
            let w = make()
            let created = w.frame
            w.orderFront(nil)
            let placed = onBackstage(w.frame)
            if !placed { w.orderOut(nil) }
            say("signal \(count): \(placed ? "backstage" : "elsewhere") \(w.frame) created \(created) main screen \(NSScreen.main?.frame ?? .zero)")
        }
    }
    source.resume()
    signalSource = source
    app.run()
    return 0
}
