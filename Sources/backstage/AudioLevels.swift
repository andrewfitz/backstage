import Foundation
/// One managed app's current audio level, for the menu bar meter. Main-thread only, cheap to call.
struct AudioLevelSample { let pid: pid_t; let name: String; let playing: Bool; let peakDb: Float; let rmsDb: Float }
protocol AudioLevelSource: AnyObject { func currentLevels() -> [AudioLevelSample] }
