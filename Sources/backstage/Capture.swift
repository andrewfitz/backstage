import Foundation
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

enum CaptureTarget {
    case window(CGWindowID)
    case app(pid_t, display: CGDirectDisplayID, crop: CGRect)          // global rect; includes menus/sheets/popovers of the app
    case display(CGDirectDisplayID, crop: CGRect?)
}

/// Capture with ScreenCaptureKit. Works for windows on the (invisible) agent display.
func capture(_ target: CaptureTarget, to url: URL, scale: Double) throws -> CGSize {
    guard scale.isFinite, scale > 0 else { throw CLIError("scale must be positive and finite") }
    let img: CGImage = try runAsync {
        let visibleOnly: Bool
        switch target {
        case .window: visibleOnly = false
        case .app, .display: visibleOnly = true
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
        case .app(let pid, let did, let crop):
            guard let d = content.displays.first(where: { $0.displayID == did }) else { throw CLIError("display \(did) not found") }
            // Filter by this process's windows, not by application: an application filter also
            // captures other instances of the same bundle (another session's copy of the app).
            let windows = content.windows.filter { $0.owningApplication?.processID == pid }
            guard !windows.isEmpty else { throw CLIError("app \(pid) is no longer capturable") }
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
