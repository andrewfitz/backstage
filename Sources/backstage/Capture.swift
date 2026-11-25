import Foundation
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

enum CaptureTarget {
    case window(CGWindowID, app: ManagedApp, display: DaemonInfo)
    /// Every window of these processes (including menus, sheets, popovers), cropped to a global rect.
    case apps([ManagedApp], display: DaemonInfo, crop: CGRect)
}

/// The registration fields that must stay stable across an asynchronous capture.
struct CaptureRegistration: Equatable {
    let processStart: UInt64?
    let launchedAt: Double
    let owner: Data?
    let slot: Int

    static func snapshot(_ apps: [ManagedApp], primary: Int) -> [pid_t: Self] {
        Dictionary(apps.map { app in
            (app.pid, Self(processStart: app.processStart, launchedAt: app.launchedAt,
                           owner: app.session.map { Data($0.utf8) }, slot: app.display ?? primary))
        }, uniquingKeysWith: { first, _ in first })
    }
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
func capture(_ target: CaptureTarget, to url: URL, scale: Double) throws -> (size: CGSize, origin: CGPoint) {
    guard scale.isFinite, scale > 0 else { throw CLIError("scale must be positive and finite") }
    var declinedRetries = 1
    let img: CGImage
    let origin: CGPoint
    while true {
        if captureLock == nil { captureLock = try StateLock("capture.lock") }
        if userCaptureLock == nil {
            guard let lock = UserLock("capture.lock") else { throw CLIError("cannot lock ScreenCaptureKit for this user") }
            userCaptureLock = lock
        }
        do {
            (img, origin) = try runAsync(timeout: captureAttemptTimeout, onTimeout: CaptureTimedOut()) { try await grab(target, scale: scale) }
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
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let stream = fdopen(fd, "wb") else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        close(fd)
        throw error
    }
    // ImageIO's URL destination can replace an existing file with umask-derived permissions.
    // Feed it the already-open private file and check the buffered write before renaming.
    var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
        guard let stream = info?.assumingMemoryBound(to: FILE.self) else { return 0 }
        return fwrite(bytes, 1, count, stream)
    }, releaseConsumer: nil)
    let encoded: Bool
    if let consumer = CGDataConsumer(info: UnsafeMutableRawPointer(stream), cbks: &callbacks),
       let destination = CGImageDestinationCreateWithDataConsumer(consumer, type.identifier as CFString, 1, nil) {
        let options = isJPG ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil
        CGImageDestinationAddImage(destination, img, options)
        encoded = CGImageDestinationFinalize(destination)
    } else {
        encoded = false
    }
    let closed = fclose(stream) == 0
    guard encoded && closed else { throw CLIError("screenshot encoding failed") }
    guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return (CGSize(width: img.width, height: img.height), origin)
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
private func grab(_ target: CaptureTarget, scale: Double) async throws -> (CGImage, CGPoint) {
    let daemon: DaemonInfo
    let apps: [ManagedApp]
    let visibleOnly: Bool
    switch target {
    case .window(_, let app, let view): (daemon, apps, visibleOnly) = (view, [app], false)
    case .apps(let records, let view, _): (daemon, apps, visibleOnly) = (view, records, true)
    }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: visibleOnly)
    let did = daemon.displayID
    guard let live = liveDaemon(), live.pid == daemon.pid, live.processStart == daemon.processStart,
          live.startedAt == daemon.startedAt, live.stopping != true,
          let display = content.displays.first(where: { $0.displayID == did }),
          isOurDisplay(did), CGDisplayIsActive(did) != 0 else {
        throw CLIError("backstage display \(did) is no longer available")
    }
    let slot = apps.first?.display ?? live.primarySlot
    guard live.on(slot)?.displayID == did, displaySlots.contains(slot),
          CGDisplaySerialNumber(did) == displaySerial(slot: slot) else {
        throw CLIError("backstage display changed during capture")
    }

    let requested = CaptureRegistration.snapshot(apps, primary: live.primarySlot)
    func validateRegistrations() throws {
        let current = try AppStore.read { requested[$0.pid] != nil }
        guard CaptureRegistration.snapshot(current, primary: live.primarySlot) == requested else {
            throw CLIError("managed apps changed during capture; try again")
        }
    }

    // Authorization may change while waiting for either lock or any ScreenCaptureKit call.
    try validateRegistrations()
    let bounds = CGDisplayBounds(did)
    let cfg = SCStreamConfiguration()
    cfg.showsCursor = false
    cfg.captureResolution = .best
    if #available(macOS 14.2, *) { cfg.includeChildWindows = false }
    let filter: SCContentFilter
    let size: CGSize
    let origin: CGPoint
    switch target {
    case .window(let wid, let app, _):
        guard let w = content.windows.first(where: {
            $0.windowID == wid && $0.owningApplication?.processID == app.pid && $0.frame.intersects(bounds)
        }) else { throw CLIError("window \(wid) not capturable on the backstage display") }
        filter = SCContentFilter(desktopIndependentWindow: w)
        size = w.frame.size
        origin = CGPoint(x: w.frame.minX - bounds.minX, y: w.frame.minY - bounds.minY)
        cfg.ignoreShadowsSingleWindow = true
        cfg.scalesToFit = true
    case .apps(_, _, let crop):
        let windows = content.windows.filter { $0.owningApplication.map { requested[$0.processID] != nil } ?? false }
        guard !windows.isEmpty else { throw CLIError("none of the requested apps has a capturable window") }
        filter = SCContentFilter(display: display, including: windows)
        // The caller computes the crop against the original display's bounds; the display may
        // have moved while the locks were busy. Preserve the requested display-relative crop.
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        let local = crop.offsetBy(dx: -daemon.bounds.minX, dy: -daemon.bounds.minY).intersection(localBounds)
        guard !local.isEmpty else { throw CLIError("screenshot crop is outside the display") }
        cfg.sourceRect = local
        size = local.size
        origin = local.origin
    }
    let width = (size.width * scale).rounded()
    let height = (size.height * scale).rounded()
    guard width >= 1, height >= 1, width * height <= 64 * 1024 * 1024 else {
        throw CLIError("scaled screenshot must have positive dimensions and at most 64 megapixels")
    }
    cfg.width = Int(width)
    cfg.height = Int(height)
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    guard let current = liveDaemon(), current.pid == live.pid, current.processStart == live.processStart,
          current.startedAt == live.startedAt, current.stopping != true,
          let display = current.on(slot), display.displayID == did, display.bounds == bounds else {
        throw CLIError("backstage display changed during capture")
    }
    try validateRegistrations()
    return (image, origin)
}
