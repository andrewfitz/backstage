import ColorSync
import CoreGraphics
import Foundation

/// Backstage displays ColorSync still has registered but that aren't attached: left over from
/// versions that gave every BACKSTAGE_HOME its own display identity (a new one per test run).
/// ColorSync walks every registered device whenever a display comes or goes, so a long list
/// costs CPU (docs/MULTI_DISPLAY_PLAN.md). Matched by the name backstage gives its displays and
/// only when not attached, so the user's displays and a live backstage display never count.
enum DisplayRegistry {
    static let displayName = "Backstage"
    /// Every name backstage has given its displays (1.3.2 and earlier: "Backstage (agent display)"):
    /// leftovers registered under an old name still count.
    static let displayNames: Set<String> = [displayName, "Backstage (agent display)"]

    static func attachedKeys() -> Set<String>? {
        guard let online = onlineDisplays() else { return nil }
        var keys = Set<String>()
        for id in online {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let key = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            keys.insert(key)
        }
        return keys
    }

    /// Device IDs of unattached backstage displays registered with ColorSync. Nil when the
    /// attached displays can't all be identified: then nothing may be called a leftover.
    static func leftovers() -> [CFUUID]? {
        final class Collector {
            let attached: Set<String>
            var seen = Set<String>()
            var found: [CFUUID] = []
            init(attached: Set<String>) { self.attached = attached }
        }
        guard let attached = attachedKeys() else { return nil }
        let collector = Collector(attached: attached)
        let context = Unmanaged.passUnretained(collector).toOpaque()
        withExtendedLifetime(collector) {
            ColorSyncIterateDeviceProfiles({ info, context in
                guard let context, let d = info as? [String: Any] else { return true }
                let c = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
                guard (d[kColorSyncDeviceClass.takeUnretainedValue() as String] as? String) == (kColorSyncDisplayDeviceClass.takeUnretainedValue() as String),
                      (d[kColorSyncDeviceDescription.takeUnretainedValue() as String] as? String).map(DisplayRegistry.displayNames.contains) == true,
                      let raw = d[kColorSyncDeviceID.takeUnretainedValue() as String] as CFTypeRef?,
                      CFGetTypeID(raw) == CFUUIDGetTypeID() else { return true }
                let uuid = raw as! CFUUID
                let key = CFUUIDCreateString(nil, uuid) as String
                if !c.attached.contains(key), c.seen.insert(key).inserted { c.found.append(uuid) }
                return true
            }, context)
        }
        return collector.found
    }

    /// Past this many leftovers, doctor suggests the cleanup.
    static let warnAbove = 8

    static var cleanupCommand: String { "sudo \(selfCommandPath()) cleanup-displays" }
}

/// `cleanup-displays`: unregister the leftover backstage displays. ColorSync only honours this
/// from root (a normal user's request is accepted and changes nothing), so it refuses otherwise.
func cmdCleanupDisplays() throws -> [String: Any] {
    guard geteuid() == 0 else {
        throw CLIError("cleanup-displays needs root: ColorSync ignores this from a normal user. Run: \(DisplayRegistry.cleanupCommand)")
    }
    guard let before = DisplayRegistry.leftovers() else { throw CLIError("couldn't identify every attached display, so nothing was removed; try again") }
    var removed = 0
    for uuid in before {
        // Recheck right before each removal: a backstage display may have come up meanwhile.
        guard let attached = DisplayRegistry.attachedKeys() else { break }
        guard let key = CFUUIDCreateString(nil, uuid) as String?, !attached.contains(key) else { continue }
        if ColorSyncUnregisterDevice(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid) { removed += 1 }
    }
    let after = DisplayRegistry.leftovers()?.count ?? -1
    return ["found": before.count, "unregistered": removed, "remaining": after]
}
