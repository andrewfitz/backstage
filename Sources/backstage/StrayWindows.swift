import AppKit
import ApplicationServices

// Stray windows: windows of apps backstage doesn't manage that sit on a backstage display, where
// the user can't see or reach them. Usually an app restoring a window to where it last was:
// backstage displays keep fixed identities, so macOS remembers them like any monitor, and an app
// once sent backstage (or one whose window was dragged off the edge) can reopen there.
// The daemon returns them to the user's screen by itself (except apps a `backstage launch`
// opened); `backstage recover` and the menu's Recover Lost Windows do it on demand.

struct StrayWindow {
    let pid: pid_t
    let windowID: CGWindowID
    let app: String
    let title: String
    let frame: CGRect
    /// The backstage display's slot, when it has one of the fixed serials.
    let slot: Int?
    /// The process carries a backstage launch token: `backstage launch` opened it (an agent's
    /// app, perhaps handed over). The daemon leaves these to an explicit recovery.
    let launched: Bool
    let policy: NSApplication.ActivationPolicy

    var json: [String: Any] {
        var d: [String: Any] = ["pid": pid, "app": app, "title": title, "window": Int(windowID),
                                "frame": ["x": Int(frame.minX), "y": Int(frame.minY), "w": Int(frame.width), "h": Int(frame.height)]]
        if let slot { d["display"] = slot }
        return d
    }
    var label: String { "'\(title)' of pid \(pid) (\(app))" + (slot.map { " on display \($0)" } ?? "") }
}

/// The process belongs to a managed app: it is one, descends from one, or is a process macOS
/// holds one responsible for (XPC services, test helpers).
func belongsToManagedApp(_ pid: pid_t, managed: Set<pid_t>) -> Bool {
    if managed.contains(pid) { return true }
    var p = parentPid(pid)
    for _ in 0..<32 {
        guard let q = p, q > 1 else { break }
        if managed.contains(q) { return true }
        p = parentPid(q)
    }
    guard let r = responsiblePid(pid), r != pid, r > 1 else { return false }
    if managed.contains(r) { return true }
    p = parentPid(r)
    for _ in 0..<32 {
        guard let q = p, q > 1 else { break }
        if managed.contains(q) { return true }
        p = parentPid(q)
    }
    return false
}

private let launchKey = "BACKSTAGE_LAUNCH_ID"

/// On-screen, ordinary (layer 0) windows on the given backstage displays whose owner isn't a
/// managed app, a helper of one, or an app a launch in progress is opening.
/// `displays`: bounds, with the slot of each. A window counts when its centre is on one
/// (parked displays touch the user's screens at a corner).
/// `windows`: an on-screen window list already fetched this tick (`onscreenWindows()`).
func findStrayWindows(displays: [(slot: Int?, bounds: CGRect)], managed: Set<pid_t>,
                      pendingLaunches: Set<String>, windows: [[String: Any]]? = nil) -> [StrayWindow] {
    guard !displays.isEmpty else { return [] }
    let list = windows ?? onscreenWindows()
    var verdicts: [pid_t: (ok: Bool, launched: Bool, policy: NSApplication.ActivationPolicy, name: String)] = [:]
    var found: [StrayWindow] = []
    for w in list {
        guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
              let number = w[kCGWindowNumber as String] as? Int else { continue }
        let f = cgBounds(w)
        guard !f.isNull, f.width >= 60, f.height >= 40,
              let on = displays.first(where: { $0.bounds.contains(CGPoint(x: f.midX, y: f.midY)) }) else { continue }
        let verdict: (ok: Bool, launched: Bool, policy: NSApplication.ActivationPolicy, name: String)
        if let v = verdicts[pid] {
            verdict = v
        } else if belongsToManagedApp(pid, managed: managed) {
            verdict = (false, false, .prohibited, "")
            verdicts[pid] = verdict
        } else {
            let running = NSRunningApplication(processIdentifier: pid)
            let token = processEnvironmentValue(pid, key: launchKey)
                ?? responsiblePid(pid).flatMap { $0 != pid ? processEnvironmentValue($0, key: launchKey) : nil }
            let pending = token.map { pendingLaunches.contains($0) } ?? false
            let ok = running != nil && running?.isTerminated == false && !pending
            verdict = (ok, token != nil, running?.activationPolicy ?? .prohibited,
                       running?.localizedName ?? (w[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)")
            verdicts[pid] = verdict
        }
        guard verdict.ok, verdict.policy != .prohibited else { continue }
        found.append(StrayWindow(pid: pid, windowID: CGWindowID(number), app: verdict.name,
                                 title: w[kCGWindowName as String] as? String ?? "", frame: f, slot: on.slot,
                                 launched: verdict.launched, policy: verdict.policy))
    }
    return found
}

/// Test-only (tests/strays.sh): return windows to this backstage display instead of the user's
/// screen, so a test never puts a window there. That display is never searched for strays.
let strayTestTargetSlot: Int? = ProcessInfo.processInfo.environment["BACKSTAGE_TEST_STRAY_TARGET"].flatMap(Int.init)

/// Where returned windows go: the main display (menu bar), or another of the user's.
func strayTargetScreen() -> CGRect? {
    if let slot = strayTestTargetSlot {
        return activeDisplays().first { isOurDisplay($0) && displaySlot(serial: CGDisplaySerialNumber($0)) == slot }.map { CGDisplayBounds($0) }
    }
    let users = userDisplayBounds()
    let main = CGDisplayBounds(CGMainDisplayID())
    return users.first(where: { $0 == main }) ?? users.first
}

/// Move stray windows onto the user's screen: centred, cascaded, shrunk to fit if needed.
/// Never activates anything unless `activate` (an explicit request by the user).
/// `axTimeout`: per accessibility call (the daemon's guard loop keeps it short: a busy app is
/// retried later). Returns the windows that moved.
@discardableResult
func returnStrayWindows(_ strays: [StrayWindow], activate: Bool = false, axTimeout: Float = 0.5, log: (String) -> Void) -> [StrayWindow] {
    guard !strays.isEmpty, let target = strayTargetScreen() else { return [] }
    let area = CGRect(x: target.minX, y: target.minY + 25, width: target.width, height: target.height - 25)
    var moved: [StrayWindow] = []
    for (pid, group) in Dictionary(grouping: strays, by: { $0.pid }) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        let windows = app.windows
        for s in group {
            // The AX window for this CG window: by window number, else by frame.
            guard let w = windows.first(where: { $0.windowID == s.windowID })
                    ?? windows.first(where: { $0.frame.map { abs($0.minX - s.frame.minX) < 2 && abs($0.minY - s.frame.minY) < 2 } == true }) else {
                log("stray window \(s.label): no accessibility window to move")
                continue
            }
            AXUIElementSetMessagingTimeout(w, axTimeout)
            var size = w.size ?? s.frame.size
            if size.width > area.width || size.height > area.height {
                size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
            }
            let i = CGFloat(moved.count % 8) * 30
            let origin = CGPoint(x: max(area.minX, area.midX - size.width / 2 + i),
                                 y: max(area.minY, area.midY - size.height / 2 + i))
            guard w.setPosition(origin) == .success else {
                log("stray window \(s.label): couldn't move it")
                continue
            }
            if size != (w.size ?? size) { w.setSize(size) }
            moved.append(s)
            log("returned stray window \(s.label) to the user's screen")
        }
    }
    if activate, let first = moved.first, let running = NSRunningApplication(processIdentifier: first.pid) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(first.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if !running.isActive { running.activate() }
    }
    return moved
}

/// What an explicit recovery (the CLI, the menu) returns: stray windows on this home's displays
/// (another home's daemon has its own registry), of any app, with no grace period.
func recoverableStrays(managed: Set<pid_t>, displays: [(slot: Int?, bounds: CGRect)]) -> [StrayWindow] {
    findStrayWindows(displays: displays.filter { strayTestTargetSlot == nil || $0.slot != strayTestTargetSlot },
                     managed: managed, pendingLaunches: Set(Launching.records().map { $0.id }))
}

/// `backstage recover [--dry-run]`: return every stray window on this home's displays to the
/// user's screen. Runs here, not in the daemon, so it works with any daemon version.
func cmdRecover(_ args: Args) throws -> [String: Any] {
    guard let d = liveDaemon() else { return ["ok": true, "recovered": [], "note": "backstage isn't running: no hidden display"] }
    let entries = d.displays ?? [DisplayEntry(slot: d.primarySlot, displayID: d.displayID, x: d.x, y: d.y, width: d.width, height: d.height)]
    // Live bounds: a display may have been re-parked since daemon.json was written.
    let displays = entries.map { e -> (slot: Int?, bounds: CGRect) in
        (e.slot, activeDisplays().contains(e.displayID) ? CGDisplayBounds(e.displayID) : CGRect(x: e.x, y: e.y, width: e.width, height: e.height))
    }
    let strays = recoverableStrays(managed: Set(AppStore.load().filter { $0.matchesProcess }.map { $0.pid }), displays: displays)
    if args.has("dry-run") {
        return ["ok": true, "stray": strays.map { $0.json }, "note": strays.isEmpty ? "no stray windows" : "--dry-run: nothing moved"]
    }
    guard strayTargetScreen() != nil || strays.isEmpty else { throw CLIError("no user display to return windows to") }
    let moved = returnStrayWindows(strays) { appendLogLine("\(ISO8601DateFormatter().string(from: Date())) recover: \($0)\n", to: Paths.log) }
    let missed = strays.filter { s in !moved.contains { $0.windowID == s.windowID } }
    var out: [String: Any] = ["ok": missed.isEmpty, "recovered": moved.map { $0.json }]
    if !missed.isEmpty { out["failed"] = missed.map { $0.json } }
    if strays.isEmpty { out["note"] = "no stray windows" }
    return out
}
