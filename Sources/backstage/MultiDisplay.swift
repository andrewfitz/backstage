import AppKit
import ApplicationServices
import Foundation

// Several displays per daemon (docs/MULTI_DISPLAY_PLAN.md, phase 2): the CLI side.

/// Ask the daemon for a display: "new" (a fresh one, reserved for this session) or a slot
/// number (created if this daemon may run it, refused if another session reserved it). Returns
/// the slot. The daemon creates displays itself: a virtual display lives as long as its process.
func requestDisplay(_ want: String, info: DaemonInfo, session: Session) throws -> Int {
    guard info.displays != nil else {
        throw CLIError("the running backstage daemon (pid \(info.pid)) predates --display; `backstage stop --all` replaces it")
    }
    if let n = Int(want), n == info.primarySlot { return n }
    let request = DisplayRequest(id: UUID().uuidString, session: session.id, want: want, at: Date().timeIntervalSince1970)
    try Paths.ensureDirectory(Paths.requests)
    let file = Paths.requests.appendingPathComponent("\(request.id).json")
    let replyFile = Paths.requests.appendingPathComponent("\(request.id).reply")
    try writeJSON(file, request)
    defer {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: replyFile)
    }
    // Creating and parking a display takes a moment; the daemon answers within its next tick.
    guard let reply = waitFor(timeout: 15, interval: 0.05, { readJSON(replyFile, DisplayReply.self) }) else {
        throw CLIError("the backstage daemon didn't answer the display request (see \(Paths.log.path))")
    }
    guard reply.ok, let slot = reply.slot else { throw CLIError(reply.error ?? "display request refused") }
    // Wait until daemon.json lists it, so the caller can place windows on it.
    guard waitFor(timeout: 5, { liveDaemon()?.entry(slot) != nil || slot == info.primarySlot ? true : nil }) != nil else {
        throw CLIError("display \(slot) didn't appear in the daemon's state")
    }
    return slot
}

/// The display a launch goes on: --display N|new, else where this session already has apps
/// (its most recent one), else the primary.
func launchDisplay(_ option: String?, info: DaemonInfo, session: Session) throws -> Int {
    if let want = option {
        guard want == "new" || Int(want) != nil else { throw CLIError("--display takes a display number or new") }
        return try requestDisplay(want, info: info, session: session)
    }
    let latest = (try? AppStore.read(matching: { Session.sameID($0.session, session.id) }))?
        .filter { $0.matchesProcess }
        .max { $0.launchedAt < $1.launchedAt }
    if let slot = latest?.display, info.entry(slot) != nil { return slot }
    return info.primarySlot
}

/// `move --display N|new`: move one of this session's apps (and its windows) to another display.
func cmdMove(_ args: Args) throws -> [String: Any] {
    guard let want = args.opt("display") else { throw CLIError("move needs --display N (or new)") }
    let app = try managedApp(args)
    let session = try Session.current()
    let info = try requireDaemon()
    let from = app.display ?? info.primarySlot
    let slot = try requestDisplay(want, info: info, session: session)
    guard let live = liveDaemon(), let view = live.on(slot) else { throw CLIError("display \(slot) isn't running") }
    if slot == from { return ["pid": app.pid, "display": slot, "moved": 0] }
    let lock = try Locks.app(app)
    defer { lock.release() }
    // `show` may have handed the app to the user meanwhile: then it's theirs, leave it alone.
    var updated = 0
    try AppStore.update { apps in
        for i in apps.indices where apps[i].pid == app.pid && apps[i].processStart == app.processStart && apps[i].owner == app.owner {
            apps[i].display = slot == live.primarySlot ? nil : slot
            updated += 1
        }
    }
    guard updated > 0 else { throw CLIError("pid \(app.pid) is no longer a managed app (it was shown on the user's screen or quit)") }
    // Place its windows on the new display; the daemon's guard keeps them there from now on.
    var placed: [CGRect] = []
    var moved = 0
    for w in axApp(app.pid).windows where (w.attr(kAXMinimizedAttribute) as? Bool) != true {
        placed.append(placeBeside(w, display: view.bounds, avoiding: placed))
        moved += 1
    }
    return ["pid": app.pid, "from": from, "display": slot, "moved": moved,
            "windows": axWindowsSummary(app.pid, origin: view.bounds.origin)]
}

/// The displays for `status`: each with its apps, reservation and recording indices (from one
/// snapshot of the active displays: hot-plugging renumbers them).
func displaysStatus(_ d: DaemonInfo) -> [[String: Any]] {
    let entries = d.displays ?? [DisplayEntry(slot: d.primarySlot, displayID: d.displayID, x: d.x, y: d.y, width: d.width, height: d.height)]
    let active = activeDisplays()
    let apps = AppStore.load().filter { $0.matchesProcess }
    return entries.map { e in
        var out: [String: Any] = ["display": e.slot, "displayID": e.displayID, "primary": e.slot == d.primarySlot,
                                  "globalOrigin": ["x": Int(e.x), "y": Int(e.y)],
                                  "apps": apps.filter { ($0.display ?? d.primarySlot) == e.slot }.count]
        if let by = e.reserved(), let until = e.reservedUntil {
            out["reservedBy"] = by
            out["reservedUntil"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: until))
        }
        if let i = active.firstIndex(of: e.displayID) {
            out["screencaptureDisplay"] = i + 1
            out["ffmpegScreen"] = "Capture screen \(i)"
        }
        return out
    }
}
