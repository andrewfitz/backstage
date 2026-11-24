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
//      TESTAPP_POLICY=none -> never sets an activation policy (otherwise it makes itself a regular app)
//      TESTAPP_TONE=<hz>  -> an inaudible probe tone (see Tone below), started on the process's first line,
//                            before any window: >= 18 kHz, -60 dBFS, 10 ms ramped edges, bursts <= 2 s.
//                            TESTAPP_TONE_PATTERN="on,off,on,off…" in ms (default "300,700", repeating;
//                            "none": silent until a burst), TESTAPP_TONE_ONCE=1 plays the pattern once and stops
//                            output, TESTAPP_TONE_SILENT=1 runs output with zero samples,
//                            TESTAPP_TONE_DEVICE=<uid> plays to that device instead of the default output.
//                            Actions > Tone Burst plays one TESTAPP_BURST_MS (default 100) burst with output started
//                            just for it; Actions > Stop Tone stops output.
import Cocoa
import CoreAudio
import AVFoundation

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

/// The probe tone. Played through a raw HAL IOProc on the chosen device: AUHAL and AVAudioEngine
/// first attach to the default output, and attaching IO to a device that has input streams makes
/// macOS 27 ask for the Microphone in this app's name (measured). So a device with inputs is
/// refused unless this app's Microphone access is already decided (TESTAPP_TONE_ALLOW_MIC_PROMPT=1
/// overrides, to raise that prompt on purpose once).
final class Tone {
    static var shared: Tone?
    let hz: Double, amplitude = pow(10.0, -60.0 / 20.0)
    let device: AudioObjectID, rate: Double, ramp: Int
    var segments: [Int] = []      // frames: on, off, on, off…
    var once = false, silent = false
    var seg = 0, pos = 0, phase = 0.0, finished = false
    var proc: AudioDeviceIOProcID?, running = false, firstRender = false
    let lock = NSLock()

    static func clock() -> Double {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1e9
    }

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["TESTAPP_TONE"] else { return }
        guard let hz = Double(s), hz >= 18000, hz <= 22000 else { log("tone refused: TESTAPP_TONE must be 18000-22000 Hz"); return }
        var device = AudioObjectID(0)
        if let uid = env["TESTAPP_TONE_DEVICE"] {
            guard let d = Tone.devices().first(where: { Tone.uid($0) == uid }) else { log("tone refused: no device \(uid)"); return }
            device = d
        } else {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device)
        }
        if Tone.channels(device, input: true) > 0 && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            && env["TESTAPP_TONE_ALLOW_MIC_PROMPT"] != "1" {
            log("tone skipped: \(Tone.uid(device) ?? "?") has input streams and this app's Microphone access isn't decided, so playing would raise a Microphone prompt")
            print("fixture tone skipped (microphone undecided)"); fflush(stdout)
            return
        }
        var rate = Float64(48000)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &rate)
        guard hz < rate / 2 else { log("tone refused: \(hz) Hz is above Nyquist at \(rate)"); return }
        let t = Tone(hz: hz, device: device, rate: rate)
        t.silent = env["TESTAPP_TONE_SILENT"] == "1"
        t.once = env["TESTAPP_TONE_ONCE"] == "1"
        Tone.shared = t
        let pattern = env["TESTAPP_TONE_PATTERN"] ?? "300,700"
        log("tone ready hz=\(Int(hz)) device=\(Tone.uid(device) ?? "?") rate=\(Int(rate)) channels=\(Tone.channels(device, input: false))")
        if pattern != "none" {
            let ms = pattern.split(separator: ",").compactMap { Double($0) }
            guard !ms.isEmpty, ms.enumerated().allSatisfy({ $0.offset % 2 == 1 || $0.element <= 2000 }), ms.allSatisfy({ $0 >= 0 }) else {
                log("tone refused: TESTAPP_TONE_PATTERN must be on,off… ms with bursts <= 2000"); return
            }
            t.play(ms)
        }
        // Stop output once a single pass is over (from the main thread, not the IO thread).
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            t.lock.lock(); let done = t.finished; t.lock.unlock()
            if done && t.running { t.stop() }
        }
    }

    init(hz: Double, device: AudioObjectID, rate: Double) {
        self.hz = hz; self.device = device; self.rate = rate; ramp = Int(0.010 * rate)
    }

    func play(_ ms: [Double]) {
        lock.lock()
        segments = ms.map { Int($0 / 1000 * rate) }
        if segments.count % 2 == 1 { segments.append(0) }
        seg = 0; pos = 0; finished = false
        lock.unlock()
        start()
    }

    func start() {
        guard !running else { return }
        if proc == nil {
            AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [unowned self] _, _, _, output, _ in self.render(output) }
        }
        firstRender = false
        let t = Tone.clock()
        let err = AudioDeviceStart(device, proc)
        running = err == noErr
        log("tone output started at \(String(format: "%.4f", t)) err=\(err)")
    }

    func stop() {
        guard running, let proc else { return }
        AudioDeviceStop(device, proc)
        running = false
        log("tone output stopped at \(String(format: "%.4f", Tone.clock()))")
    }

    func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(output)
        lock.lock(); defer { lock.unlock() }
        if !firstRender { firstRender = true; let t = Tone.clock(); DispatchQueue.main.async { log("tone first render at \(String(format: "%.4f", t))") } }
        var base = 0
        let step = 2 * Double.pi * hz / rate
        let frames = abl.first.map { Int($0.mDataByteSize) / 4 / max(Int($0.mNumberChannels), 1) } ?? 0
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var g = 0.0
            while seg < segments.count && pos >= segments[seg] {
                pos = 0; seg += 1
                if seg >= segments.count { if once { finished = true } else { seg = 0 } }
            }
            if seg < segments.count && seg % 2 == 0 && !finished {
                let len = segments[seg]
                g = min(1, Double(pos) / Double(ramp), Double(len - 1 - pos) / Double(ramp))
                g = 0.5 - 0.5 * cos(Double.pi * max(0, g))
            }
            if seg < segments.count && !finished { pos += 1 }
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            samples[i] = silent ? 0 : Float(amplitude * g * sin(phase))
        }
        for b in abl {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(Int(b.mNumberChannels), 1), n = min(frames, Int(b.mDataByteSize) / 4 / ch)
            for i in 0..<n { for c in 0..<ch { d[i * ch + c] = base + c < 2 ? samples[i] : 0 } }
            base += ch
        }
    }

    /// Actions > Tone Burst: start output just for one burst; stop it once the burst is over.
    @objc static func burst() {
        guard let t = shared else { return }
        let ms = Double(ProcessInfo.processInfo.environment["TESTAPP_BURST_MS"] ?? "100") ?? 100
        guard ms > 0, ms <= 2000 else { return }
        t.stop()
        t.once = true
        log("tone burst \(Int(ms)) ms requested at \(String(format: "%.4f", Tone.clock()))")
        t.play([ms, 300])
    }
    @objc static func stopTone() { shared?.stop() }

    static func devices() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids
    }
    static func uid(_ d: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }
    static func channels(_ d: AudioObjectID, input: Bool) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                           mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// The probe starts on the process's first line, before any window (TESTAPP_TONE).
Tone.startIfRequested()

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
// TESTAPP_POLICY=none leaves the policy alone (a bundled app's default), like most apps: an app
// `backstage launch` started without a Dock tile then never gets one (tests/dock.sh).
if ProcessInfo.processInfo.environment["TESTAPP_POLICY"] != "none" {
    app.setActivationPolicy(ProcessInfo.processInfo.environment["TESTAPP_ACCESSORY"] == "1" ? .accessory : .regular)
}
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
if Tone.shared != nil {
    actMenu.addItem(withTitle: "Tone Burst", action: #selector(Tone.burst), keyEquivalent: "").target = Tone.self
    actMenu.addItem(withTitle: "Stop Tone", action: #selector(Tone.stopTone), keyEquivalent: "").target = Tone.self
}
let editItem = NSMenuItem(); menu.addItem(editItem)
let editMenu = NSMenu(title: "Edit"); editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); editItem.submenu = editMenu
app.mainMenu = menu
app.run()
