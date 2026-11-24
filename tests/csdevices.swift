// Prints how many backstage displays ColorSync has registered (attached or not).
import ColorSync
import Foundation

final class Counter { var n = 0 }
let counter = Counter()
withExtendedLifetime(counter) {
    ColorSyncIterateDeviceProfiles({ info, context in
        guard let context, let d = info as? [String: Any],
              (d[kColorSyncDeviceDescription.takeUnretainedValue() as String] as? String) == "Backstage (agent display)" else { return true }
        Unmanaged<Counter>.fromOpaque(context).takeUnretainedValue().n += 1
        return true
    }, Unmanaged.passUnretained(counter).toOpaque())
}
print(counter.n)
