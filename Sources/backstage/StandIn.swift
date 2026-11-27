import Foundation
import AppKit
import CoreGraphics

// No monitor attached (switched off, a headless Mac, a remote desktop, VNC or Screen Sharing
// session, SSH): with only backstage's hidden display left, macOS would make it the main screen,
// move the user's windows onto it, and stream it to remote viewers, agents' apps and all. macOS
// puts up a generic fallback screen of its own only when no display exists at all, so backstage's
// display blocks that. Instead the daemon puts up a stand-in screen (`isStandInDisplay`): a
// virtual display with an identity of its own that everything treats as one of the user's
// screens. It's made the main display, the hidden displays are parked at its corner as usual,
// and windows of the user's apps that macOS moved onto a hidden display go back (the stray-window
// rule, StrayWindows.swift). Once a real display has been back for a few seconds, it's made the
// main display again and the stand-in goes.
//
// The stand-in lives in a display host like any backstage display (role "standin"), so a daemon
// restart keeps it, and there's at most one per user: a daemon whose home doesn't have it waits
// for the other home's to appear rather than making a second.

extension Daemon {
    enum StandInState { case ready, waiting, failed(String) }

    /// Called with no user screen left. Puts up (or waits for) the stand-in screen.
    func ensureStandIn() -> StandInState {
        if let s = standIn, DisplayHosts.alive(s), (onlineDisplays() ?? []).contains(s.displayID) {
            standInWaitSince = nil
            return .ready
        }
        standIn = nil
        let now = ProcessInfo.processInfo.systemUptime
        if (onlineDisplays() ?? []).contains(where: isStandInDisplay) {
            // Another home's daemon has one (it shows as a user screen once active).
            let since = standInWaitSince ?? now
            standInWaitSince = since
            return now - since < 10 ? .waiting : .failed("another daemon's stand-in display didn't become active")
        }
        let size = displaySize
        do {
            let (info, _) = try spawnDisplayHost(width: size.width, height: size.height, scale: size.scale, choice: .home,
                                                 role: "standin", linger: DisplayHosts.homeLinger())
            standIn = info
            standInWaitSince = nil
            log("no display attached: put up a stand-in screen (display \(info.displayID), \(size.width)x\(size.height) points), "
                + "so the hidden display stays hidden and remote sessions see a normal desktop")
            makeMain(info.displayID)
            return .ready
        } catch {
            return .failed("\(error)")
        }
    }

    /// Make `id` the main display (the one at the origin), with this daemon's displays out of its
    /// way at its bottom-right corner; repark() then fine-tunes them.
    func makeMain(_ id: CGDirectDisplayID) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        let main = CGDisplayBounds(id)
        var x = Int32(main.width), y = Int32(main.height)
        CGConfigureDisplayOrigin(cfg, id, 0, 0)
        for d in allDisplays where d.id != id {
            CGConfigureDisplayOrigin(cfg, d.id, x, y)
            x += Int32(d.bounds.width)
            y += Int32(d.bounds.height)
        }
        if CGCompleteDisplayConfiguration(cfg, .forSession) != .success {
            log("couldn't make display \(id) the main display")
        }
    }

    /// Once a second: a real display has been back for 3 s straight while this daemon's stand-in
    /// is up: make it the main display and remove the stand-in (its windows move to the real one).
    func checkStandIn(now: Double) {
        guard let s = standIn else { realDisplaySince = nil; return }
        guard DisplayHosts.alive(s) else {
            log("the stand-in display's host (pid \(s.pid)) exited")
            standIn = nil
            scheduleRepark()
            return
        }
        let real = activeDisplays().filter {
            !isOurDisplay($0) && !isStandInDisplay($0) && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay
        }
        guard let first = real.first else { realDisplaySince = nil; return }
        let since = realDisplaySince ?? now
        realDisplaySince = since
        guard now - since >= 3 else { return }
        if CGMainDisplayID() == s.displayID || !real.contains(CGMainDisplayID()) { makeMain(first) }
        log("a display is back (\(first)): removing the stand-in screen")
        DisplayHosts.end((s.pid, s.start), id: s.id, displayID: s.displayID)
        standIn = nil
        realDisplaySince = nil
        scheduleRepark()
    }
}
