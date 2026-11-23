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
/// products) in a throwaway .app whose executable is a tiny exec shim.
func wrapExecutable(_ exe: URL) throws -> URL {
    try Paths.ensure()
    let name = exe.lastPathComponent
    let hash = SHA256.hash(data: Data(exe.path.utf8)).map { String(format: "%02x", $0) }.joined()
    let app = Paths.wrappers.appendingPathComponent("\(hash).app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    let shim = macos.appendingPathComponent(name)
    func shellLiteral(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    let script = """
        #!/bin/sh
        cd \(shellLiteral(exe.deletingLastPathComponent().path)) || exit 1
        case "$BACKSTAGE_LAUNCH_ID" in
            ''|*[!0-9A-Fa-f-]*) ;;
            *) receipt=\(shellLiteral(Paths.appLogs.path))/"$BACKSTAGE_LAUNCH_ID.pid"
               if [ -f "$receipt" ]; then printf '%s\\n' "$$" > "$receipt" || exit 1; fi ;;
        esac
        exec \(shellLiteral(exe.path)) "$@"

        """
    if (try? String(contentsOf: shim, encoding: .utf8)) != script {
        try script.write(to: shim, atomically: true, encoding: .utf8)
    }
    guard chmod(shim.path, 0o755) == 0 else { throw CLIError("couldn't make wrapper executable") }
    let plist: [String: Any] = [
        "CFBundleExecutable": name,
        "CFBundleIdentifier": "dev.backstage.wrapped.\(hash)",
        "CFBundleName": name,
        "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": true,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    return app
}

func launch(_ args: Args) throws -> [String: Any] {
    guard let target = args.pos(0) else { throw CLIError("usage: backstage launch <app|bundle-id|path> [--env K=V] [--timeout S] [-- app args…]") }
    var url = try resolveApp(target)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw CLIError("app disappeared at \(url.path)") }
    let bareExecutable = isDir.boolValue ? nil : url.resolvingSymlinksInPath().standardizedFileURL
    if !isDir.boolValue {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CLIError("\(url.path) is not an app bundle or executable") }
        url = try wrapExecutable(url)
    }
    let timeout = args.double("timeout") ?? 15
    guard !args.has("timeout"), timeout.isFinite, timeout >= 0, timeout < Double(Int.max),
          args.opt("timeout") == nil || args.double("timeout") != nil else { throw CLIError("invalid --timeout") }
    guard Bundle(url: url)?.executableURL != nil else { throw CLIError("missing app executable at \(url.path)") }
    guard AXIsProcessTrusted() else {
        throw CLIError("launch requires Accessibility permission for the terminal or agent host in System Settings > Privacy & Security > Accessibility")
    }
    return try withLaunchSession { info in
        try launchResolved(url, bareExecutable: bareExecutable, args: args, info: info, timeout: timeout)
    }
}

// Darwin returns argc, the executable path, alignment padding, argv, then the environment.
private func hasLaunchToken(_ pid: pid_t, assignment: String) -> Bool {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return false }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return false }
    let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = MemoryLayout<Int32>.size
    guard argc > 0, let endOfPath = bytes[index..<size].firstIndex(of: 0) else { return false }
    index = endOfPath
    while index < size && bytes[index] == 0 { index += 1 }
    for _ in 0..<argc {
        guard let end = bytes[index..<size].firstIndex(of: 0) else { return false }
        index = end + 1
    }
    while index < size && bytes[index] != 0 {
        guard let end = bytes[index..<size].firstIndex(of: 0) else { return false }
        if bytes[index..<end].elementsEqual(assignment.utf8) { return true }
        index = end + 1
    }
    return false
}

private func launchResolved(_ url: URL, bareExecutable: URL?, args: Args, info: DaemonInfo, timeout: Double) throws -> [String: Any] {
    let vd = info.bounds
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
    defer { if bareExecutable != nil { try? FileManager.default.removeItem(at: receipt) } }

    // -g: don't bring to foreground, -j: launch hidden, -n: fresh instance (never touch the user's copy)
    var openArgs = ["-g", "-j", "-n", "--stdout", logURL.path, "--stderr", logURL.path]
    for e in env + [assignment] { openArgs += ["--env", e] }
    openArgs.append(url.path)
    if !args.passthrough.isEmpty { openArgs += ["--args"] + args.passthrough }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = openArgs
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw CLIError("open failed (status \(p.terminationStatus))") }

    let bundleURL = url.resolvingSymlinksInPath().standardizedFileURL
    func ownsLog(_ pid: pid_t) -> Bool {
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            var detail = vnode_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: detail))
            if proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEINFO, &detail, size) == size,
               detail.pvi.vi_stat.vst_ino == logStat.st_ino,
               detail.pvi.vi_stat.vst_dev == UInt32(bitPattern: logStat.st_dev) { return true }
        }
        return false
    }
    func receiptPID() -> pid_t? {
        guard let value = try? String(contentsOf: receipt, encoding: .utf8) else { return nil }
        return pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func matchesExecutable(_ pid: pid_t, _ target: URL) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var expected = stat(), actual = stat()
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 &&
            stat(target.path, &expected) == 0 && stat(path, &actual) == 0 &&
            actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
    }
    func findApp() -> (NSRunningApplication?, pid_t, UInt64)? {
        let candidate: NSRunningApplication?
        let pid: pid_t
        if bareExecutable != nil {
            guard let reported = receiptPID(), reported > 0, !before.contains(reported) else { return nil }
            pid = reported
            candidate = NSRunningApplication(processIdentifier: pid)
        } else {
            candidate = NSWorkspace.shared.runningApplications.first {
                !before.contains($0.processIdentifier) && !$0.isTerminated
                    && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundleURL
                    && (ownsLog($0.processIdentifier) || hasLaunchToken($0.processIdentifier, assignment: assignment))
            }
            guard let candidate else { return nil }
            pid = candidate.processIdentifier
        }
        guard let birth = processBirth(pid) else { return nil }
        let app = candidate.flatMap { $0.processIdentifier == pid && !$0.isTerminated ? $0 : nil }
        if let target = bareExecutable {
            guard receiptPID() == pid, matchesExecutable(pid, target),
                  ownsLog(pid) || hasLaunchToken(pid, assignment: assignment) else { return nil }
        } else if app == nil { return nil }
        guard processBirth(pid) == birth else { return nil }
        return (app, pid, birth)
    }
    guard let (app, pid, birth) = waitFor(timeout: 15, { findApp() }) else {
        throw CLIError("open accepted \(url.path), but its process could not be identified. Launch log: \(logURL.path)")
    }
    func stillRunning() -> Bool { processBirth(pid) == birth }
    func currentApp() -> NSRunningApplication? {
        guard stillRunning() else { return nil }
        let current = app.flatMap { $0.isTerminated ? nil : $0 } ?? NSRunningApplication(processIdentifier: pid)
        guard let current, current.processIdentifier == pid, !current.isTerminated else { return nil }
        return current
    }
    do {
        try AppStore.add(ManagedApp(pid: pid, name: name, bundleID: bid, path: url.path,
                                    launchedAt: Date().timeIntervalSince1970, stdout: logURL.path,
                                    processStart: birth))
    } catch {
        if let current = currentApp() { _ = current.forceTerminate() }
        else if stillRunning() { _ = kill(pid, SIGTERM) }
        throw error
    }

    let gotWindow = waitFor(timeout: timeout) {
        if !stillRunning() { return false }
        return axApp(pid).windows.isEmpty ? nil : true
    } ?? false
    pump(0.3)
    guard stillRunning() else { throw CLIError("app exited before window placement") }
    for w in axApp(pid).windows { placeBeside(w, display: vd) }
    pump(0.1)
    let placed = waitFor(timeout: 1) {
        guard stillRunning() else { return false }
        let placed = axApp(pid).windows.allSatisfy { window in
            (window.attr(kAXMinimizedAttribute) as? Bool) == true
                || window.frame.map { vd.contains($0) } == true
        }
        if !placed { adoptWindows(pid: pid, display: vd) }
        return placed ? true : nil
    } ?? false
    let canUnhide = currentApp()
    if placed {
        _ = canUnhide?.unhide()
        if gotWindow {
            _ = waitFor(timeout: 3) {
                !stillRunning() || onscreenWindows().contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid } ? true : nil
            }
        }
        guard stillRunning() else { throw CLIError("app exited during launch") }
        adoptWindows(pid: pid, display: vd)
    }
    guard stillRunning() else { throw CLIError("app exited during launch") }

    var result: [String: Any] = [
        "pid": pid, "name": name, "path": url.path,
        "windows": axWindowsSummary(pid, origin: vd.origin),
        "log": logURL.path,
    ]
    if let bid { result["bundleID"] = bid }
    if !placed { result["warning"] = "window placement could not be verified; backstage skipped unhiding the app" }
    else if gotWindow && canUnhide == nil { result["warning"] = "AppKit did not provide a running application handle for unhiding the windows" }
    else if !gotWindow { result["warning"] = "no window appeared within \(Int(timeout))s (app may be windowless or still loading); new windows will be moved to the agent display automatically" }
    if let f0 = front0, NSWorkspace.shared.frontmostApplication?.processIdentifier != f0 {
        result["note"] = "focus changed during launch; daemon will hand it back"
    }
    return result
}
