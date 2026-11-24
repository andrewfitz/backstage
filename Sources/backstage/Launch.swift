import Foundation
import AppKit
import CryptoKit
import ApplicationServices

/// Resolve an app argument: path to .app, path to a bare executable, bundle id, or app name.
func resolveApp(_ arg: String) throws -> URL {
    let fm = FileManager.default
    let expanded = (arg as NSString).expandingTildeInPath
    if fm.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded).standardizedFileURL }
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arg) { return u }
    let name = arg.hasSuffix(".app") ? arg : arg + ".app"
    let home = fm.homeDirectoryForCurrentUser.path
    for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", "\(home)/Applications"] {
        let p = "\(dir)/\(name)"
        if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
    }
    throw CLIError("can't find app '\(arg)' (give a path, bundle id, or name in /Applications)")
}

/// LaunchServices can only launch-hidden a bundle, so wrap bare executables (e.g. `swift build`
/// products) in a throwaway .app. For `launch`, the wrapper's executable is a symlink to the
/// binary: LaunchServices starts the binary itself, so it keeps the UIElement type `launch` asks
/// for (an exec'ing shim makes it a regular app again). The process starts in `/`, like any app
/// LaunchServices opens. `show` uses a separate wrapper (its own bundle ID, so LaunchServices never
/// routes it to an instance `launch` runs hidden) whose shell shim runs the binary from its directory.
func wrapExecutable(_ exe: URL, shown: Bool = false) throws -> URL {
    try Paths.ensure()
    let name = exe.lastPathComponent
    let hash = SHA256.hash(data: Data(exe.path.utf8)).map { String(format: "%02x", $0) }.joined()
    let app = Paths.wrappers.appendingPathComponent(shown ? "\(hash)-shown.app" : "\(hash).app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    let fm = FileManager.default
    try fm.createDirectory(at: macos, withIntermediateDirectories: true)
    let executable = macos.appendingPathComponent(name)
    if shown {
        func shellLiteral(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let script = """
            #!/bin/sh
            cd \(shellLiteral(exe.deletingLastPathComponent().path)) || exit 1
            exec \(shellLiteral(exe.path)) "$@"

            """
        var metadata = stat()
        if lstat(executable.path, &metadata) != 0
            || metadata.st_mode & S_IFMT != S_IFREG
            || metadata.st_mode & 0o777 != 0o755
            || (try? String(contentsOf: executable, encoding: .utf8)) != script {
            let temp = macos.appendingPathComponent(".\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try script.write(to: temp, atomically: true, encoding: .utf8)
            guard chmod(temp.path, 0o755) == 0, rename(temp.path, executable.path) == 0 else {
                throw CLIError("couldn't create wrapper for \(exe.path)")
            }
        }
    } else {
        let target = exe.resolvingSymlinksInPath().path
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: executable.path)) != target {
            // Replace atomically (an older wrapper has a shell shim here; another launch may race).
            let temp = macos.appendingPathComponent(".\(name).\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: target)
            guard rename(temp.path, executable.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw CLIError("couldn't create wrapper for \(exe.path)")
            }
        }
    }
    let plist: [String: Any] = [
        "CFBundleExecutable": name,
        "CFBundleIdentifier": shown ? "dev.backstage.shown.\(hash)" : "dev.backstage.wrapped.\(hash)",
        "CFBundleName": name,
        "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": true,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let info = app.appendingPathComponent("Contents/Info.plist")
    if (try? Data(contentsOf: info)) != data { try data.write(to: info, options: .atomic) }
    return app
}

/// The app is built on Qt, which makes itself a regular (Dock) app at startup unless told not to.
private func usesQt(_ app: URL, executable: URL?) -> Bool {
    let fm = FileManager.default
    let frameworks = app.appendingPathComponent("Contents/Frameworks")
    if let names = try? fm.contentsOfDirectory(atPath: frameworks.path),
       names.contains(where: { $0 == "QtCore.framework" || ($0.hasPrefix("libQt") && $0.contains("Core")) }) { return true }
    // Linked libraries are named in the Mach-O header's load commands, near the start of the file.
    guard let exe = executable ?? Bundle(url: app)?.executableURL,
          let handle = try? FileHandle(forReadingFrom: exe) else { return false }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 1 << 20)) ?? Data()
    return head.range(of: Data("QtCore".utf8)) != nil
}

func launch(_ args: Args) throws -> [String: Any] {
    guard let target = args.pos(0) else { throw CLIError("usage: backstage launch <app|bundle-id|path> [--env K=V] [--timeout S] [--dock] [--audio | --inaudible] [-- app args…]") }
    let timeout: Double
    if let value = args.opt("timeout") {
        guard let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else {
            throw CLIError("invalid --timeout")
        }
        timeout = seconds
    } else {
        timeout = 15
    }
    var url = try resolveApp(target)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw CLIError("app disappeared at \(url.path)") }
    let bareExecutable = isDir.boolValue ? nil : url.resolvingSymlinksInPath().standardizedFileURL
    if !isDir.boolValue {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CLIError("\(url.path) is not an app bundle or executable") }
        url = try wrapExecutable(url)
    }
    guard let bundleExecutable = Bundle(url: url)?.executableURL else { throw CLIError("missing app executable at \(url.path)") }
    // The process LaunchServices starts: the bundle's executable, or (through the wrapper's
    // symlink) the bare executable itself.
    let audio = try planAudio(args, executable: bareExecutable ?? bundleExecutable,
                              name: bareExecutable?.lastPathComponent ?? url.deletingPathExtension().lastPathComponent)
    guard AXIsProcessTrusted() else {
        throw CLIError("launch requires Accessibility permission for the terminal or agent host in System Settings > Privacy & Security > Accessibility")
    }
    guard audioSupported() else { throw CLIError("audio muting needs macOS 14.2 or later, so backstage can't launch apps on this Mac") }
    let session = try Session.current()
    let started = Date().timeIntervalSince1970
    let (info, lifecycle) = try beginLaunch()
    defer { lifecycle.release() }
    // Muting is unconditional: no app starts unless the daemon can mute it.
    try requireAudioMuting(info)
    return try launchResolved(url, bareExecutable: bareExecutable, args: args, info: info, timeout: timeout,
                              session: session, started: started, lifecycle: lifecycle, hideFromDock: !args.has("dock"),
                              audio: audio)
}

private func launchResolved(_ url: URL, bareExecutable: URL?, args: Args, info: DaemonInfo, timeout: Double,
                            session: Session, started: Double, lifecycle: StateLock, hideFromDock: Bool,
                            audio plan: AudioPlan) throws -> [String: Any] {
    var audio = plan
    // Which display: --display N|new, else where this session already has apps, else the primary.
    let slot = try launchDisplay(args.opt("display"), info: info, session: session)
    // A display just created is in the daemon's info only from now on.
    let current = slot == info.primarySlot || info.entry(slot) != nil ? info : (liveDaemon() ?? info)
    guard let view = current.on(slot) else { throw CLIError("display \(slot) isn't running") }
    let vd = view.bounds
    let recordSlot: Int? = slot == current.primarySlot ? nil : slot
    let bundle = Bundle(url: url)
    let bid = bundle?.bundleIdentifier
    let name = (bundle?.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent

    let before = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
    let front0 = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let launchID = UUID().uuidString
    let tokenKey = "BACKSTAGE_LAUNCH_ID"
    let assignment = "\(tokenKey)=\(launchID)"
    let env = args.multi("env")
    guard !env.contains(where: { $0 == tokenKey || $0.hasPrefix(tokenKey + "=") }) else {
        throw CLIError("\(tokenKey) is reserved for launch identification")
    }
    guard !env.contains(where: { $0.hasPrefix(InaudibleLibrary.ackKey + "=") }) else {
        throw CLIError("\(InaudibleLibrary.ackKey) is reserved for inaudible launches")
    }
    let logURL = Paths.appLogs.appendingPathComponent("\(launchID).log")
    let fd = open(logURL.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CLIError("couldn't create launch log at \(logURL.path)") }
    defer { close(fd) }
    var logStat = stat()
    guard fstat(fd, &logStat) == 0 else { throw CLIError("couldn't identify launch log") }

    let receipt = Paths.appLogs.appendingPathComponent("\(launchID).pid")
    if bareExecutable != nil {
        let receiptFD = open(receipt.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard receiptFD >= 0 else { throw CLIError("could not create wrapper PID receipt") }
        close(receiptFD)
    }
    // A provisional record lets the daemon clean up if this process dies before registering
    // the app: it quits what the launch started. If instead the app's process doesn't appear in
    // time, the record is handed over (kept, with the receipt): the daemon registers the app to
    // this session if it turns up late.
    var leaveToDaemon = false
    defer { if bareExecutable != nil && !leaveToDaemon { try? FileManager.default.removeItem(at: receipt) } }
    let launcher = launchingAgent()
    var provisional = LaunchRecord(id: launchID, session: session.id, cliPID: getpid(), cliStart: processBirth(getpid()) ?? 0,
                                   bundle: url.path, executable: bareExecutable?.path, log: logURL.path,
                                   startedAt: Date().timeIntervalSince1970, audio: audio.mode.rawValue,
                                   agent: launcher?.name, agentPID: launcher?.pid,
                                   commandStartedAt: started, forcedInaudible: audio.forced ? true : nil, display: recordSlot)
    try Launching.begin(provisional)
    defer { if !leaveToDaemon { Launching.end(launchID) } }

    var environment: [String: String] = [:]
    for entry in env + [assignment] {
        let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        environment[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
    }
    // Qt makes its apps regular (Dock) apps at startup unless this is set.
    let qtKey = "QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM"
    if hideFromDock, environment[qtKey] == nil, usesQt(url, executable: bareExecutable) { environment[qtKey] = "1" }
    // Inaudible: dyld loads the library into the app before its own code runs (and into every
    // child that inherits the variable and accepts it). LaunchServices passes DYLD_* through.
    if audio.mode == .inaudible, let library = audio.library {
        let insert = "DYLD_INSERT_LIBRARIES"
        environment[insert] = ([library.path] + (environment[insert].map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: ":")
        environment[InaudibleLibrary.ackKey] = InaudibleLibrary.ackFile(launchID).path
    }

    let clock = ProcessInfo.processInfo
    var reportedPID: pid_t?
    var launchedAt = clock.systemUptime
    var hidden = hideFromDock
    var request: LaunchServices.OpenRequest?
    if LaunchServices.canOpen {
        // What /usr/bin/open -g -j -n does, through LaunchServices directly, plus (unless --dock)
        // the private option that starts the app as a UIElement: no Dock tile, not in ⌘-Tab.
        hidden = hideFromDock && LaunchServices.canHideFromDock
        request = try LaunchServices.openApplication(url, .init(hideFromDock: hidden, environment: environment,
                                                                arguments: args.passthrough, log: logURL))
    } else {
        // -g: don't bring to foreground, -j: launch hidden, -n: fresh instance (never touch the user's copy)
        hidden = false
        var openArgs = ["-g", "-j", "-n", "--stdout", logURL.path, "--stderr", logURL.path]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { openArgs += ["--env", "\(key)=\(value)"] }
        openArgs.append(url.path)
        if !args.passthrough.isEmpty { openArgs += ["--args"] + args.passthrough }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = openArgs
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CLIError("open failed (status \(p.terminationStatus))") }
    }

    // Identify the new process. LaunchServices' answer names it, but under heavy load the answer
    // can come long after the process started, or never: the process is also found by its launch
    // token or log (LaunchTarget), whether or not LaunchServices answered. --timeout (the
    // first-window wait) doesn't shorten this; see Launching.deadlines.
    let identity = LaunchTarget(bundle: url.resolvingSymlinksInPath().standardizedFileURL, executable: bareExecutable,
                                launchID: launchID, logDevice: logStat.st_dev, logInode: logStat.st_ino, receipt: receipt)
    let notBefore = provisional.startedAt - 1
    let blind = LaunchServices.testHooks.contains("no-find")
    func findApp() -> (NSRunningApplication?, pid_t, UInt64)? {
        if blind { return nil }
        // The PID LaunchServices reported, once it's verifiably this launch's process; else a search.
        if let pid = reportedPID, !before.contains(pid), let found = identity.verify(pid) { return found }
        return identity.find { pid in
            pid != reportedPID && !before.contains(pid) && (processBirth(pid).map { Double($0) / 1e6 >= notBefore } ?? false)
        }
    }
    let deadlines = Launching.deadlines()
    let opened = clock.systemUptime
    var answeredAt: Double? = request == nil ? opened : nil
    var refusal: String?
    var identified: (NSRunningApplication?, pid_t, UInt64)?
    while identified == nil {
        // Tapped on sight and failed: the daemon is quitting it; don't wait for it to register.
        if let failure = audioFailure(launch: launchID) { throw CLIError(failure) }
        if answeredAt == nil, let answer = request?.answer {
            answeredAt = clock.systemUptime
            launchedAt = clock.systemUptime
            if answer.ok {
                reportedPID = answer.pid
                if let pid = reportedPID, bareExecutable != nil, !before.contains(pid) {
                    // The wrapper runs the binary directly, so the CLI writes the receipt the
                    // daemon's orphan cleanup reads.
                    try? "\(pid)\n".write(to: receipt, atomically: false, encoding: .utf8)
                }
            } else {
                refusal = answer.error ?? "unknown error"
            }
        }
        identified = findApp()
        if identified != nil { break }
        if let refusal { throw CLIError("LaunchServices couldn't open \(url.path): \(refusal)") }
        let now = clock.systemUptime
        if now - opened >= deadlines.total || answeredAt.map({ now - $0 >= deadlines.afterAnswer }) == true { break }
        pump(0.05)
    }
    guard let (app, pid, birth) = identified else {
        // LaunchServices can still start it after the CLI gives up waiting.
        leaveToDaemon = true
        let later: String
        if info.delayedLaunchHandoff == true {
            provisional.handedOver = true
            do { try Launching.begin(provisional) } catch {
                throw CLIError("couldn't hand the pending launch to the daemon: \(error). Launch log: \(logURL.path)")
            }
            later = "if it starts later, the daemon checks it before registering it to this session. See `backstage list` for pending launches and registered apps"
        } else {
            later = "the running daemon will try to quit the app if it appears during launch cleanup"
        }
        let waited = Int((clock.systemUptime - opened).rounded())
        let details = "; \(later). Launch log: \(logURL.path)"
        if request != nil && answeredAt == nil {
            throw CLIError("LaunchServices didn't answer within \(waited)s opening \(url.path) and no process of this launch appeared"
                + (deadlines.heavyLoad ? " (the system is under heavy load)" : "") + details)
        }
        throw CLIError("LaunchServices opened \(url.path), but its process could not be identified within \(waited)s" + details)
    }
    var launchWarning: String?
    if request != nil, let answered = answeredAt, answered - opened > 10 {
        launchWarning = "LaunchServices took \(Int(answered - opened))s to answer (the system may be under heavy load)"
    } else if request != nil, answeredAt == nil {
        launchWarning = String(format: "LaunchServices hadn't answered after %.1fs (the system may be under heavy load); backstage identified the app by its launch token", clock.systemUptime - opened)
        launchedAt = clock.systemUptime
    }
    func stillRunning() -> Bool { processBirth(pid) == birth }
    /// The app is gone: say why if the daemon quit it because its audio couldn't be muted.
    func exited(_ fallback: String) -> CLIError { CLIError(audioFailure(pid, birth) ?? fallback) }
    func currentApp() -> NSRunningApplication? {
        guard stillRunning() else { return nil }
        let current = app.flatMap { $0.isTerminated ? nil : $0 } ?? NSRunningApplication(processIdentifier: pid)
        guard let current, current.processIdentifier == pid, !current.isTerminated else { return nil }
        return current
    }
    func terminateUnregisteredApp() {
        if let current = currentApp(), current.forceTerminate() { return }
        if stillRunning() { _ = kill(pid, SIGTERM) }
    }
    if audio.mode == .inaudible, let library = audio.library,
       let why = confirmInaudible(pid: pid, launchID: launchID, library: library) {
        if audio.forced {
            terminateUnregisteredApp()
            leaveToDaemon = stillRunning()
            throw CLIError("\(name) didn't become inaudible, so backstage quit it: \(why)")
        }
        audio.mode = .muted
        audio.reason = "\(why); muted on this Mac's outputs only, so screen sharing and recordings can still hear it"
    }
    let placementLock: StateLock
    do {
        let owner = try Locks.session(session.id)
        defer { owner.release() }
        if let stopped = try owner.readStamp(), stopped >= started {
            throw CLIError("`backstage stop` ran in this session during the launch, so the app was quit")
        }
        let record = ManagedApp(pid: pid, name: name, bundleID: bid, path: url.path,
                                launchedAt: Date().timeIntervalSince1970, stdout: logURL.path,
                                processStart: birth, agent: launcher?.name, agentPID: launcher?.pid,
                                session: session.id, audio: audio.mode.rawValue, display: recordSlot)
        // Handover and input must wait until this launch finishes moving its windows.
        placementLock = try Locks.app(record)
        try AppStore.add(record)
        Launching.end(launchID)
    } catch {
        terminateUnregisteredApp()
        leaveToDaemon = stillRunning()
        if let failure = audioFailure(launch: launchID) ?? audioFailure(pid, birth) { throw CLIError(failure) }
        throw error
    }
    defer { placementLock.release() }
    // The daemon now guards the registered app. Release the lock shared with daemon shutdown
    // while keeping the per-app lock for window placement.
    lifecycle.release()

    let accessibility = axApp(pid)
    let initialWindows = waitFor(timeout: timeout) { () -> [AXUIElement]? in
        if !stillRunning() { return [] }
        let windows = accessibility.windows
        return windows.isEmpty ? nil : windows
    } ?? accessibility.windows
    guard stillRunning() else { throw exited("app exited before window placement") }
    var gotWindow = !initialWindows.isEmpty
    // The app is still hidden, so its own windows aren't on screen yet: keep them apart too.
    var placedFrames: [CGRect] = []
    var crowded = false
    for w in initialWindows {
        let placement = placeBesideReporting(w, display: vd, avoiding: placedFrames)
        placedFrames.append(placement.frame)
        crowded = crowded || placement.cascaded
    }
    func isContained(_ window: AXUIElement) -> Bool {
        (window.attr(kAXMinimizedAttribute) as? Bool) == true || window.frame.map { vd.contains($0) } == true
    }
    let placed = waitFor(timeout: 1) {
        guard stillRunning() else { return false }
        // The convenience .windows property also returns an empty list when AX fails.
        guard let windows = try? accessibility.readElements(kAXWindowsAttribute) else { return nil }
        gotWindow = gotWindow || !windows.isEmpty
        let placed = windows.allSatisfy(isContained)
        if !placed { adoptWindows(pid: pid, display: vd) }
        return placed ? true : nil
    } ?? false
    let canUnhide = currentApp()
    if placed {
        _ = canUnhide?.unhide()
        if gotWindow {
            let raiseAt = ProcessInfo.processInfo.systemUptime + 0.5
            var raised = false
            _ = waitFor(timeout: 3) {
                if !stillRunning() || onscreenWindows().contains(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }) { return true }
                // Accessory (LSUIElement-style) apps launched hidden keep their windows off screen
                // after being unhidden, until they think they're active. Send the private "you're
                // active" event every first input sends anyway (the real frontmost app doesn't
                // change), then raise the windows, which were checked to be on the agent display.
                if !raised && ProcessInfo.processInfo.systemUptime >= raiseAt {
                    guard let windows = try? accessibility.readElements(kAXWindowsAttribute), !windows.isEmpty else { return nil }
                    guard windows.allSatisfy(isContained) else {
                        adoptWindows(pid: pid, display: vd)
                        return nil
                    }
                    raised = true
                    primeActivation(pid)
                    for w in windows where (w.attr(kAXMinimizedAttribute) as? Bool) != true
                        && w.frame.map({ vd.contains($0) }) == true {
                        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    }
                }
                return nil
            }
        }
        guard stillRunning() else { throw exited("app exited during launch") }
        adoptWindows(pid: pid, display: vd)
    }
    guard stillRunning() else { throw exited("app exited during launch") }
    if let failure = audioFailure(pid, birth) {
        // The daemon is quitting it.
        throw CLIError(failure)
    }

    var result: [String: Any] = [
        "pid": pid, "name": name, "path": url.path,
        "windows": axWindowsSummary(pid, origin: vd.origin),
        "display": slot,
        "log": logURL.path,
    ]
    if let bid { result["bundleID"] = bid }
    result["audio"] = audio.mode.rawValue
    if let reason = audio.reason { result["audioReason"] = reason }
    if info.audioModes != true && !audio.mode.metered {
        result["audioWarning"] = "the running backstage daemon is from an older build that measures every app, so this one's tap runs IO while it plays "
            + "(the system's recording indicator shows); `backstage stop --all` (quits every managed app) replaces it"
    }
    // An app that makes itself a regular app does so within moments of starting.
    result["dock"] = dockState(pid, requested: hideFromDock, hidden: hidden, until: launchedAt + 1)
    guard stillRunning() else { throw exited("app exited during launch") }
    if !placed { result["warning"] = "window placement could not be verified; backstage skipped unhiding the app" }
    else if gotWindow && canUnhide == nil { result["warning"] = "AppKit did not provide a running application handle for unhiding the windows" }
    else if !gotWindow { result["warning"] = "no window appeared within \(Int(timeout))s (app may be windowless or still loading); new windows will be moved to the agent display automatically" }
    if crowded {
        result["crowded"] = true
        let hint = "display \(slot) is crowded: no free spot for this window, so it overlaps others; `launch --display new` gives you a display of your own"
        result["warning"] = [result["warning"] as? String, hint].compactMap { $0 }.joined(separator: "; ")
    }
    if let launchWarning {
        result["warning"] = [launchWarning, result["warning"] as? String].compactMap { $0 }.joined(separator: "; ")
    }
    if let f0 = front0, NSWorkspace.shared.frontmostApplication?.processIdentifier != f0 {
        result["note"] = "focus changed during launch; daemon will hand it back"
    }
    return result
}

/// The agent that ran this command (known agent CLIs first, else the first non-shell ancestor),
/// for the menu bar's per-app label.
func launchingAgent() -> (name: String, pid: Int32)? {
    let chain = Session.ancestors()
    if let a = chain.first(where: { $0.agent != nil }), let name = a.agent { return (name, a.pid) }
    return chain.first(where: { !$0.skipped }).map { (name: $0.name, pid: $0.pid) }
}
