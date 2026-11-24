import Foundation
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

enum CaptureTarget {
    case window(CGWindowID)
    /// Every window of these processes (including menus, sheets, popovers), cropped to a global rect.
    case apps(Set<pid_t>, display: CGDirectDisplayID, crop: CGRect)
    case display(CGDirectDisplayID, crop: CGRect?)
}

/// ScreenCaptureKit calls from two processes at once hang on macOS 27.0.1: `SCShareableContent`
/// and `captureImage` never return, in every process involved, until those processes exit. So:
/// - captures take `capture.lock` and keep it until the process exits (`captureLock`), since a
///   client that has finished its calls but is still running can still collide with the next one;
///   then the same lock shared by every BACKSTAGE_HOME (`userCaptureLock`): the hang doesn't care
///   which daemon a process belongs to;
/// - an attempt that doesn't answer within `captureAttemptTimeout` runs the command again once
///   in a fresh process image (`retryCaptureInFreshProcess`), which ends the stuck call and
///   closes both locks on exec;
/// - ScreenCaptureKit sometimes fails a capture with a spurious "user declined" (-3801) while
///   other sessions capture; that is retried once.
let captureAttemptTimeout = 4.0
private var captureLock: StateLock?
private var userCaptureLock: UserLock?
private struct CaptureTimedOut: Error {}

/// Capture with ScreenCaptureKit. Works for windows on the (invisible) agent display.
func capture(_ target: CaptureTarget, to url: URL, scale: Double) throws -> CGSize {
    guard scale.isFinite, scale > 0 else { throw CLIError("scale must be positive and finite") }
    var declinedRetries = 1
    let img: CGImage
    while true {
        if captureLock == nil { captureLock = try StateLock("capture.lock") }
        if userCaptureLock == nil {
            guard let lock = UserLock("capture.lock") else { throw CLIError("cannot lock ScreenCaptureKit for this user") }
            userCaptureLock = lock
        }
        do {
            img = try runAsync(timeout: captureAttemptTimeout, onTimeout: CaptureTimedOut()) { try await grab(target, scale: scale) }
            break
        } catch is CaptureTimedOut {
            try retryCaptureInFreshProcess()
        } catch let error as NSError where error.domain == SCStreamErrorDomain
                    && error.code == SCStreamError.Code.userDeclined.rawValue && declinedRetries > 0 {
            declinedRetries -= 1
            usleep(200_000)
        }
    }
    let isJPG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    let type = isJPG ? UTType.jpeg : UTType.png
    // Encode to a sibling file so large screenshots need no in-memory encoded copy
    // and an interrupted write leaves the previous output intact.
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".backstage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
        throw CLIError("cannot create screenshot in \(url.deletingLastPathComponent().path)")
    }
    let options = isJPG ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil
    CGImageDestinationAddImage(destination, img, options)
    guard CGImageDestinationFinalize(destination) else { throw CLIError("screenshot encoding failed") }
    guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return CGSize(width: img.width, height: img.height)
}

/// A ScreenCaptureKit call that hangs stays hung until its process goes away, and keeps later
/// captures hanging while it lives. Run this same command again, once, in a fresh process image:
/// `exec` ends the stuck call and closes the lock descriptors. Releasing either lock earlier
/// could let another process enter ScreenCaptureKit while the stuck call is still alive.
private func retryCaptureInFreshProcess() throws -> Never {
    let marker = "BACKSTAGE_CAPTURE_RETRY"
    guard ProcessInfo.processInfo.environment[marker] == nil else {
        throw CLIError("ScreenCaptureKit did not answer, twice (\(Int(captureAttemptTimeout))s each); try again in a moment")
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else {
        throw CLIError("ScreenCaptureKit did not answer within \(Int(captureAttemptTimeout))s; try again")
    }
    setenv(marker, "1", 1)
    fflush(stdout); fflush(stderr)
    let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    execv(path, argv)
    throw CLIError("ScreenCaptureKit did not answer, and the retry could not start: \(String(cString: strerror(errno)))")
}

/// One ScreenCaptureKit capture of `target`.
private func grab(_ target: CaptureTarget, scale: Double) async throws -> CGImage {
    let visibleOnly: Bool
    switch target {
    case .window: visibleOnly = false
    case .apps, .display: visibleOnly = true
    }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: visibleOnly)
    let cfg = SCStreamConfiguration()
    cfg.showsCursor = false
    cfg.captureResolution = .best
    let filter: SCContentFilter
    let size: CGSize
    switch target {
    case .window(let wid):
        guard let w = content.windows.first(where: { $0.windowID == wid }) else { throw CLIError("window \(wid) not capturable") }
        filter = SCContentFilter(desktopIndependentWindow: w)
        size = w.frame.size
        cfg.ignoreShadowsSingleWindow = true
    case .apps(let pids, let did, let crop):
        guard let d = content.displays.first(where: { $0.displayID == did }) else { throw CLIError("display \(did) not found") }
        // Filter by these processes' windows, not by application: an application filter also
        // captures other instances of the same bundle (another session's copy of the app).
        // Anything else on the shared display (other sessions, out-of-process panels) is left out.
        let windows = content.windows.filter { $0.owningApplication.map { pids.contains($0.processID) } ?? false }
        guard !windows.isEmpty else {
            throw CLIError(pids.count == 1 ? "app \(pids.first!) is no longer capturable" : "none of this session's apps has a capturable window")
        }
        filter = SCContentFilter(display: d, including: windows)
        let db = CGDisplayBounds(d.displayID)
        let local = crop.intersection(db).offsetBy(dx: -db.minX, dy: -db.minY)
        guard !local.isEmpty else { throw CLIError("screenshot crop is outside the display") }
        cfg.sourceRect = local
        size = local.size
    case .display(let did, let crop):
        guard let d = content.displays.first(where: { $0.displayID == did }) else { throw CLIError("display \(did) not found") }
        filter = SCContentFilter(display: d, excludingWindows: [])
        let db = CGDisplayBounds(did)
        let local = (crop ?? db).intersection(db).offsetBy(dx: -db.minX, dy: -db.minY)
        guard !local.isEmpty else { throw CLIError("screenshot crop is outside the display") }
        cfg.sourceRect = local
        size = local.size
    }
    let width = (size.width * scale).rounded()
    let height = (size.height * scale).rounded()
    guard width >= 1, height >= 1, width * height <= 64 * 1024 * 1024 else {
        throw CLIError("scaled screenshot must have positive dimensions and at most 64 megapixels")
    }
    cfg.width = Int(width)
    cfg.height = Int(height)
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}
