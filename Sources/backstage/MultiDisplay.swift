import AppKit
import ApplicationServices
import Foundation

// Several displays per daemon (docs/MULTI_DISPLAY_PLAN.md, phase 2): the CLI side.

/// Ask the daemon for a display: "new" (a fresh one, reserved for this session) or a slot
/// number (created if this daemon may run it, refused if another session reserved it). Returns
/// the slot. The daemon creates displays itself: a virtual display lives as long as its process.
func requestDisplay(_ want: String, info: DaemonInfo, session: Session) throws -> Int {
    guard want == "new" || Int(want).map(displaySlots.contains) == true else {
        throw CLIError("--display takes a display number (1-8) or new")
    }
    guard info.displays != nil else {
        throw CLIError("the running backstage daemon (pid \(info.pid)) predates --display; `backstage stop --all` replaces it")
    }
    if let n = Int(want), n == info.primarySlot { return n }
    let reply = try exchangeDisplayRequest(DisplayRequest(id: UUID().uuidString, session: session.id, want: want,
                                                          at: Date().timeIntervalSince1970))
    guard reply.ok, let slot = reply.slot else { throw CLIError(reply.error ?? "display request refused") }
    // Wait until daemon.json lists it, so the caller can place windows on it.
    guard waitFor(timeout: 5, { () -> Bool? in
        guard let current = liveDaemon(), current.pid == info.pid, current.processStart == info.processStart,
              current.stopping != true, current.entry(slot) != nil else { return nil }
        return true
    }) != nil else {
        throw CLIError("display \(slot) didn't appear in the daemon's state")
    }
    return slot
}

/// Hand the daemon a display request (requests/<uuid>.json) and wait for its answer.
private func exchangeDisplayRequest(_ request: DisplayRequest) throws -> DisplayReply {
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
    return reply
}

/// `close-display N [--force]`: remove one of the daemon's extra displays. Its apps move to the
/// primary display first and keep running. The primary display always stays. Refused when
/// another session reserved the display or has apps on it, unless --force.
func cmdCloseDisplay(_ args: Args) throws -> [String: Any] {
    guard let raw = args.pos(0), let n = Int(raw), displaySlots.contains(n) else {
        throw CLIError("usage: backstage close-display N [--force]  (N: a display number from `backstage status`)")
    }
    let session = try Session.current()
    let lifecycle = try StateLock("lifecycle.lock", shared: true)
    defer { lifecycle.release() }
    let info = try requireDaemon()
    guard info.displays != nil else {
        throw CLIError("the running backstage daemon (pid \(info.pid)) predates several displays; `backstage stop --all` replaces it")
    }
    if n == info.primarySlot { throw CLIError("display \(n) is this daemon's first display; it always stays") }
    let reply = try exchangeDisplayRequest(DisplayRequest(id: UUID().uuidString, session: session.id, want: "close:\(n)",
                                                          at: Date().timeIntervalSince1970, force: args.has("force") ? true : nil))
    guard reply.ok else {
        // A daemon from before close-display reads "close:N" as an invalid display number.
        if reply.error?.contains("takes a display number") == true {
            throw CLIError("the running backstage daemon predates close-display; `backstage stop --all && backstage start` replaces it")
        }
        throw CLIError(reply.error ?? "close-display refused")
    }
    _ = waitFor(timeout: 7) { liveDaemon()?.entry(n) == nil ? true : nil }
    return ["ok": true, "display": n, "closed": true, "moved": reply.moved ?? [], "movedTo": info.primarySlot]
}

/// The display a launch goes on: --display N|new, else where this session already has apps
/// (its most recent one), else the primary.
func launchDisplay(_ option: String?, info: DaemonInfo, session: Session) throws -> Int {
    if let want = option {
        return try requestDisplay(want, info: info, session: session)
    }
    let latest = try AppStore.read(matching: { Session.sameID($0.session, session.id) })
        .max { $0.launchedAt < $1.launchedAt }
    if let slot = latest?.display, info.entry(slot) != nil {
        // Renew the slot's lease before writing the pending launch record. The app that
        // led us to this slot could quit before the caller can publish that record.
        return try requestDisplay(String(slot), info: info, session: session)
    }
    return info.primarySlot
}

/// `move --display N|new`: move one of this session's apps (and its windows) to another display.
func cmdMove(_ args: Args) throws -> [String: Any] {
    guard let want = args.opt("display") else { throw CLIError("move needs --display N (or new)") }
    let app = try managedApp(args)
    let session = try Session.current()
    let lifecycle = try StateLock("lifecycle.lock", shared: true)
    defer { lifecycle.release() }
    let info = try requireDaemon()
    let slot = try requestDisplay(want, info: info, session: session)
    let lock = try Locks.app(app)
    defer { lock.release() }
    guard let live = liveDaemon(), live.pid == info.pid, live.processStart == info.processStart,
          live.stopping != true, let view = live.on(slot) else { throw CLIError("display \(slot) isn't running") }
    // `show` may have handed the app to the user meanwhile: then it's theirs, leave it alone.
    var from: Int?
    try AppStore.update { apps in
        guard let i = apps.firstIndex(where: {
            $0.pid == app.pid && $0.processStart == app.processStart && $0.launchedAt == app.launchedAt
                && Session.sameID($0.owner, app.owner)
        }) else { return }
        from = apps[i].display ?? live.primarySlot
        if from != slot {
            apps[i].display = slot == live.primarySlot ? nil : slot
        }
    }
    guard let from, app.matchesProcess else {
        throw CLIError("pid \(app.pid) is no longer a managed app (it was shown on the user's screen or quit)")
    }
    if slot == from { return ["pid": app.pid, "display": slot, "moved": 0] }
    // Place its windows on the new display; the daemon's guard keeps them there from now on.
    var placed: [CGRect] = []
    var moved = 0
    let windows = axApp(app.pid).windows
    guard app.matchesProcess else { throw CLIError("pid \(app.pid) quit while moving its windows") }
    for w in windows where (w.attr(kAXMinimizedAttribute) as? Bool) != true {
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
    var appCounts: [Int: Int] = [:]
    for app in AppStore.load() { appCounts[app.display ?? d.primarySlot, default: 0] += 1 }
    return entries.map { e in
        var out: [String: Any] = ["display": e.slot, "displayID": e.displayID, "primary": e.slot == d.primarySlot,
                                  "globalOrigin": ["x": Int(e.x), "y": Int(e.y)],
                                  "apps": appCounts[e.slot, default: 0]]
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
