import Foundation
import CoreAudio
import AudioToolbox
import CBackstageAudio

/// The daemon's view of one registered app, handed to the tap manager.
struct AudioRegistryEntry: Equatable {
    let pid: pid_t
    let birth: UInt64
    let name: String
    let session: String?
    /// Launched with --audio: the tap's IO runs while it plays (levels, sounds, the ring). Other
    /// apps are only muted.
    let metered: Bool

    init(_ app: ManagedApp) {
        pid = app.pid; birth = app.processStart ?? 0; name = app.name; session = app.session
        metered = app.audioMode.metered
    }

    static func == (lhs: AudioRegistryEntry, rhs: AudioRegistryEntry) -> Bool {
        lhs.pid == rhs.pid && lhs.birth == rhs.birth && lhs.name == rhs.name
            && Session.sameID(lhs.session, rhs.session) && lhs.metered == rhs.metered
    }
}

/// What the daemon needs from the tap manager (which exists only on macOS 14.2+).
protocol AudioTapControl: AnyObject {
    func updateRegistry(_ entries: [AudioRegistryEntry])
    /// After the apps are gone: destroy every tap and remove the published files.
    func shutdown()
}

private struct AppKey: Hashable { let pid: pid_t; let birth: UInt64 }

/// A BSMeter allocation, freed when the last holder (tap queue or worker) lets go.
private final class MeterBox {
    let pointer: UnsafeMutablePointer<BSMeter>
    init?(channels: UInt32) {
        guard let p = bs_meter_create(channels, machSecondsPerTick) else { return nil }
        pointer = p
    }
    deinit { bs_meter_destroy(pointer) }
}

/// The published 15 s ring file, mapped shared so the IOProc writes it without syscalls.
private final class RingBox {
    let url: URL
    let base: UnsafeMutableRawPointer
    let size: Int
    var header: UnsafeMutablePointer<BSRingHeader> { base.assumingMemoryBound(to: BSRingHeader.self) }
    var data: UnsafeMutablePointer<Float> { (base + 64).assumingMemoryBound(to: Float.self) }

    init?(url: URL, sampleRate: Double, channels: Int, gain: Double) {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000,
              channels > 0, channels <= 32 else { return nil }
        let capacity = Int(audioRingSeconds * sampleRate)
        size = 64 + capacity * channels * MemoryLayout<Float>.size
        let temporary = url.appendingPathExtension(UUID().uuidString)
        let fd = open(temporary.path, O_CREAT | O_RDWR | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer {
            close(fd)
            unlink(temporary.path)
        }
        guard ftruncate(fd, off_t(size)) == 0,
              let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED else { return nil }
        base = p
        self.url = url
        memset(base, 0, size)   // touch every page now, not in the IOProc
        let h = header
        h.pointee.magic = (0x42, 0x53, 0x41, 0x52)   // "BSAR"
        h.pointee.version = 1
        h.pointee.sampleRate = sampleRate
        h.pointee.channels = UInt32(channels)
        h.pointee.capacityFrames = UInt32(capacity)
        h.pointee.levelGain = gain
        guard rename(temporary.path, url.path) == 0 else {
            munmap(base, size)
            return nil
        }
    }
    deinit { munmap(base, size) }
}

@available(macOS 14.2, *)
private final class AppTap {
    let key: AppKey
    var name: String
    var session: String?
    var launchID: String?
    var everRegistered = false
    var members: [AppKey]                  // root first, then helpers
    var objects: [AudioObjectID] = []
    var tapID = AudioObjectID(0), aggID = AudioObjectID(0)
    var desc: CATapDescription?
    var state = "armed"
    var reason: String?
    var ioProc: AudioDeviceIOProcID?
    var ioProcRequested = false
    var ioRunning = false
    var ioStopAt: Double?
    var meter: MeterBox?
    var ring: RingBox?
    var sampleRate = 0.0
    var channels = 0
    var outputChannels = 2
    var sightToMuteMs: [Double] = []
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var rootDiedAt: Double?
    var quitRequested = false
    var nextGainCheck = 0.0
    var version = 0
    /// Launched with --audio. Otherwise the tap only mutes: no IO, no ring, no levels.
    var metered: Bool

    init(key: AppKey, name: String, session: String?, metered: Bool) {
        self.key = key; self.name = name; self.session = session; self.metered = metered
        members = [key]
    }
    var gain: Double { outputChannels > 2 ? Double(outputChannels) / 2 : 1 }
    var pids: [pid_t] { members.map { $0.pid } }
}

/// What the worker sees of an app.
private struct TapSnapshot {
    let key: AppKey
    let name: String
    let session: String?
    let state: String
    let reason: String?
    let pids: [pid_t]
    let ioRunning: Bool
    let sampleRate: Double
    let channels: Int
    let outputChannels: Int
    let gain: Double
    let sightToMuteMs: [Double]
    let meter: MeterBox?
    let ring: String?
    let launch: String?
    let metered: Bool
    let version: Int
}

/// The worker's running analysis of one app.
private final class Analysis {
    weak var meter: MeterBox?
    var blocksRead: UInt64 = 0
    var history: [(start: Double, end: Double, peak: Double, sumSquares: Double, frames: Int)] = []
    var sounds: [AudioSound] = []
    var current: (start: Double, end: Double, peak: Double, sumSquares: Double, frames: Int)?
    /// Quiet blocks after the current sound's last loud one: part of it only if it continues.
    var pendingSquares = 0.0, pendingFrames = 0
    var lastPublished = 0.0
    var lastVersion = -1
    var lastPlaying = false
    var lastIO = false
    var lastPeak: Double?
}

/// Mutes every app the daemon manages with one private, muted process tap inside a private,
/// tap-only aggregate device, created the moment the app (or one of its helpers) becomes a Core
/// Audio client. Measures through the same tap while output runs. See docs/AUDIO_PLAN.md.
///
/// Queues: `tapQueue` makes every tap/aggregate/IO call and runs the process-list and
/// is-running listeners (sight-to-mute is measured there); `ioSetupQueue` creates IOProcs and
/// runs the self-test (an IOProc's creation can block while a permission prompt is up);
/// `workerQueue` is the 20 Hz worker that turns the IOProcs' block stats into levels, sounds and
/// the published files, and caches the menu bar's levels. The main thread only hands over
/// registry snapshots and reads the cached levels.
@available(macOS 14.2, *)
final class AudioTapManager: AudioTapControl, AudioLevelSource {
    private let log: (String) -> Void
    private let quit: (_ pid: pid_t, _ birth: UInt64, _ registered: Bool) -> Void
    private let tapQueue = DispatchQueue(label: "backstage.audio.taps", qos: .userInteractive)
    private let ioSetupQueue = DispatchQueue(label: "backstage.audio.io-setup", qos: .utility)
    private let workerQueue = DispatchQueue(label: "backstage.audio.worker", qos: .utility)
    private let logQueue = DispatchQueue(label: "backstage.audio.log")
    private let testMode = ProcessInfo.processInfo.environment["BACKSTAGE_TEST_AUDIO"]

    // tapQueue
    private var apps: [AppKey: AppTap] = [:]
    private var objectOwner: [AudioObjectID: AppKey] = [:]
    private var seen: Set<AudioObjectID> = []
    private var registry: [AudioRegistryEntry] = []
    private var capturePermitted = false
    private var timer: DispatchSourceTimer?
    private var nextRescan = 0.0, nextLiveness = 0.0
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var failedFiles: [(URL, Double)] = []
    private var stopped = false
    private var restartedAt = -Double.infinity
    private let ownPid = getpid()

    // workerQueue
    private var analyses: [AppKey: Analysis] = [:]
    private var workerTimer: DispatchSourceTimer?
    private var workerTicks = 0
    private var health: AudioHealth

    // any thread
    private let levelLock = NSLock()
    private var levelCache: [AudioLevelSample] = []

    init(log: @escaping (String) -> Void, quit: @escaping (pid_t, UInt64, Bool) -> Void) {
        self.quit = quit
        let logQueue = self.logQueue
        self.log = { line in logQueue.async { log(line) } }
        let responsible = responsiblePid(getpid())
        let host = responsible.map { AudioHost(pid: $0, name: processPath($0).map { ($0 as NSString).lastPathComponent } ?? "pid \($0)", path: processPath($0)) }
        health = AudioHealth(muting: "ok", reason: nil, capture: "not granted", captureSource: "preflight", preflight: nil,
                             host: host, floorDb: audioFloorDb, updated: audioClock())
    }

    // MARK: start / stop

    /// Mute self-test, listeners and timers. Returns nil when muting works, else why not.
    /// Runs before the daemon publishes daemon.json, so no launch can race it.
    func start() -> String? {
        try? Paths.ensureDirectory(AudioFiles.dir)
        // Leftovers of a previous daemon (its taps died with it).
        if let names = try? FileManager.default.contentsOfDirectory(atPath: AudioFiles.dir.path) {
            for n in names { try? FileManager.default.removeItem(at: AudioFiles.dir.appendingPathComponent(n)) }
        }
        let failure: String? = tapQueue.sync {
            if let why = muteSelfTest() { return why }
            installSystemListeners()
            let t = DispatchSource.makeTimerSource(queue: tapQueue)
            t.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            return nil
        }
        if let failure {
            health.muting = "unavailable"; health.reason = failure
            writeHealth()
            return failure
        }
        refreshCapture(initial: true)
        let w = DispatchSource.makeTimerSource(queue: workerQueue)
        w.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(5))
        w.setEventHandler { [weak self] in self?.workerTick() }
        w.resume()
        workerTimer = w
        return nil
    }

    func shutdown() {
        tapQueue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            for app in Array(apps.values) { destroy(app, keepFile: false, why: "daemon shutdown") }
            for (a, block) in systemListeners {
                var a = a
                AudioObjectRemovePropertyListenerBlock(HAL.system, &a, tapQueue, block)
            }
            systemListeners = []
        }
        workerQueue.sync { workerTimer?.cancel(); workerTimer = nil }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: AudioFiles.dir.path) {
            for n in names { try? FileManager.default.removeItem(at: AudioFiles.dir.appendingPathComponent(n)) }
        }
        logQueue.sync {}
    }

    /// Create (and destroy) a muted tap on the daemon itself, inside a tap-only aggregate. Needs no
    /// permission and starts no IO. Proves the tap APIs work before any launch is accepted.
    private func muteSelfTest() -> String? {
        if testMode == "mute-fail" { return "mute self-test failed (BACKSTAGE_TEST_AUDIO=mute-fail)" }
        let me = HAL.processObject(for: ownPid)
        guard me != kAudioObjectUnknown else { return "Core Audio has no process object for the daemon" }
        switch makeTap(objects: [me], name: "backstage-selftest") {
        case .failure(let why): return "mute self-test: \(why)"
        case .success(let made):
            let format = HAL.tapFormat(made.tap)
            AudioHardwareDestroyAggregateDevice(made.aggregate)
            AudioHardwareDestroyProcessTap(made.tap)
            guard let format, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return "mute self-test: the tap reported no format" }
            return nil
        }
    }

    private func installSystemListeners() {
        let list: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processListChanged() }
        let restart: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.serviceRestarted() }
        for (selector, block) in [(kAudioHardwarePropertyProcessObjectList, list), (kAudioHardwarePropertyServiceRestarted, restart)] {
            var a = HAL.address(selector)
            if AudioObjectAddPropertyListenerBlock(HAL.system, &a, tapQueue, block) == noErr { systemListeners.append((a, block)) }
        }
        seen = []
    }

    // MARK: registry (main thread → tapQueue)

    func updateRegistry(_ entries: [AudioRegistryEntry]) {
        tapQueue.async { [weak self] in self?.applyRegistry(entries) }
    }

    private func applyRegistry(_ entries: [AudioRegistryEntry], rescanAfter: Bool = true) {
        guard !stopped else { return }
        registry = entries
        var added = false
        for e in entries {
            let key = AppKey(pid: e.pid, birth: e.birth)
            if apps[key] == nil { added = true }
            let app = apps[key] ?? {
                let a = AppTap(key: key, name: e.name, session: e.session, metered: e.metered)
                apps[key] = a
                return a
            }()
            if !app.everRegistered || app.name != e.name || !Session.sameID(app.session, e.session) || app.metered != e.metered { app.version += 1 }
            app.everRegistered = true; app.name = e.name; app.session = e.session
            if app.metered != e.metered {
                app.metered = e.metered
                if e.metered { prepareIO(app); evaluateIO(app) } else { stopIO(app) }
            }
        }
        // Registered before and gone from a good registry read while still alive: handed over
        // to the user (`show`), so the tap goes and the user hears the app.
        for app in Array(apps.values) where app.everRegistered && app.state != "failed"
            && !entries.contains(where: { $0.pid == app.key.pid && $0.birth == app.key.birth }) {
            guard processBirth(app.key.pid) == app.key.birth else { continue }
            // Snapshots can arrive out of order with a direct read (see match): confirm with a
            // fresh, successful read of the registry. A read error never unmutes.
            guard let current = try? AppStore.read(),
                  !current.contains(where: { $0.pid == app.key.pid && $0.processStart == app.key.birth }) else { continue }
            destroy(app, keepFile: false, why: "handed over to the user (show): unmuted")
        }
        // Newly managed apps may already be audio clients (or have helpers that are): look at
        // every unowned client now rather than at the next rescan.
        if rescanAfter && added { rescan() }
        publishCrashTable()
    }

    // MARK: matching (tapQueue)

    private func processListChanged(reconsiderUnmatched: Bool = false) {
        guard !stopped else { return }
        let now = audioClock()
        let list = HAL.processObjects()
        let present = Set(list)
        let departed = objectOwner.filter { !present.contains($0.key) }
        for object in departed.keys { objectOwner[object] = nil }
        seen.formIntersection(present)
        for object in list where objectOwner[object] == nil && (reconsiderUnmatched || !seen.contains(object)) {
            seen.insert(object)
            consider(object, sight: now)
        }
        // Detach departed listeners after examining new clients. Listener removal and
        // helper liveness checks can block while Core Audio is starting another process.
        var changed: Set<AppKey> = []
        for (object, key) in departed {
            guard let app = apps[key] else { continue }
            app.objects.removeAll { $0 == object }
            changed.insert(key)
            app.listeners.removeAll { id, address, block in
                guard id == object else { return false }
                var address = address
                AudioObjectRemovePropertyListenerBlock(id, &address, tapQueue, block)
                return true
            }
        }
        for key in changed {
            guard let app = apps[key] else { continue }
            app.members.removeAll { $0 != key && processBirth($0.pid) != $0.birth }
            app.version += 1
        }
        if !changed.isEmpty { publishCrashTable() }
    }

    /// Every half second: look again at audio clients that matched nothing (an app registered
    /// later, a helper whose parent became managed).
    private func rescan() {
        processListChanged(reconsiderUnmatched: true)
    }

    private func consider(_ object: AudioObjectID, sight: Double) {
        let lookupStarted = audioClock()
        guard let pid = HAL.pid(of: object), pid != ownPid, let identity = processIdentity(pid) else { return }
        guard let app = match(pid, identity: identity) else { return }
        add(object, pid: pid, birth: identity.birth, to: app, sight: sight, lookupStarted: lookupStarted, matched: audioClock())
    }

    private func processIdentity(_ pid: pid_t) -> (birth: UInt64, parent: pid_t)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return (info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, pid_t(info.pbi_ppid))
    }

    private func root(_ pid: pid_t) -> AppTap? {
        guard let birth = processBirth(pid) else { return nil }
        return apps[AppKey(pid: pid, birth: birth)]
    }

    /// Which managed app an audio client belongs to: the app itself, a descendant, a process
    /// macOS holds the app responsible for (XPC services), or a process carrying a pending
    /// launch's BACKSTAGE_LAUNCH_ID (tap on sight, before the launch registers the app).
    private func match(_ pid: pid_t, identity: (birth: UInt64, parent: pid_t)) -> AppTap? {
        if let a = apps[AppKey(pid: pid, birth: identity.birth)] { return a }
        var ancestor = identity.parent
        for _ in 0..<32 {
            guard ancestor > 1 else { break }
            guard let found = processIdentity(ancestor) else {
                // A zombie parent cannot own a tap but can still lead to a live ancestor.
                guard let parent = parentPid(ancestor), parent != ancestor else { break }
                ancestor = parent
                continue
            }
            if let a = apps[AppKey(pid: ancestor, birth: found.birth)] { return a }
            ancestor = found.parent
        }
        let responsible = responsiblePid(pid)
        if let r = responsible, r != pid, let a = root(r) { return a }
        // A pending launch's token: on the process itself (inherited by children), or on the
        // process macOS holds responsible for it (an XPC helper of an app that hasn't used
        // Core Audio itself yet).
        var carrier = pid
        let launchKey = "BACKSTAGE_LAUNCH_ID"
        var token = processEnvironmentValue(pid, key: launchKey)
        if token == nil, let r = responsible, r != pid, let t = processEnvironmentValue(r, key: launchKey) { carrier = r; token = t }
        guard let token else { return nil }
        let record = Launching.file(token)
        if FileManager.default.fileExists(atPath: record.path) {
            // The topmost process carrying this launch's token is the app.
            var top = carrier
            var p = carrier == pid ? identity.parent : parentPid(carrier)
            while let q = p, q > 1, processEnvironmentValue(q, key: launchKey) == token { top = q; p = parentPid(q) }
            guard let birth = processBirth(top) else { return nil }
            let key = AppKey(pid: top, birth: birth)
            if let a = apps[key] { return a }
            let launch = readJSON(record, LaunchRecord.self)
            let name = launch.map { URL(fileURLWithPath: $0.executable ?? $0.bundle).deletingPathExtension().lastPathComponent }
                ?? processPath(top).map { ($0 as NSString).lastPathComponent } ?? "pid \(top)"
            // Measured only when launched with --audio (a record without a mode predates modes).
            let a = AppTap(key: key, name: name, session: launch?.session, metered: launch.map { AudioMode($0.audio).metered } ?? false)
            a.launchID = token
            apps[key] = a
            publishCrashTable()
            return a
        }
        // The launch ended a moment ago: it registered the app, and the daemon's registry view
        // may be a tick behind. Read the registry itself before deciding it's not ours.
        let fresh = AppStore.load().map(AudioRegistryEntry.init)
        guard !fresh.isEmpty else { return nil }
        applyRegistry(fresh, rescanAfter: false)
        if let a = root(pid) { return a }
        var p = parentPid(pid)
        while let q = p, q > 1 { if let a = root(q) { return a }; p = parentPid(q) }
        return nil
    }

    // MARK: taps (tapQueue)

    private struct Made { let tap: AudioObjectID; let aggregate: AudioObjectID; let desc: CATapDescription }

    private func makeTap(objects: [AudioObjectID], name: String) -> Result<Made, TapError> {
        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.muteBehavior = .muted
        desc.isPrivate = true
        desc.name = name
        var tap = AudioObjectID(0)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { return .failure(TapError("AudioHardwareCreateProcessTap failed: \(fourCC(err))")) }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "dev.backstage.tap.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(0)
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate)
        guard err == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return .failure(TapError("AudioHardwareCreateAggregateDevice failed: \(fourCC(err))"))
        }
        return .success(Made(tap: tap, aggregate: aggregate, desc: desc))
    }

    private func add(_ object: AudioObjectID, pid: pid_t, birth: UInt64, to app: AppTap, sight: Double, lookupStarted: Double, matched: Double) {
        guard app.state != "failed" || app.tapID != 0 else { return }
        let wasPlaying = HAL.isRunningOutput(object)
        var objects = app.objects.filter { objectOwner[$0] == app.key && $0 != object }
        objects.append(object)
        if app.tapID == 0 {
            if testMode == "tap-fail" {
                fail(app, "AudioHardwareCreateProcessTap failed (BACKSTAGE_TEST_AUDIO=tap-fail)")
                return
            }
            switch makeTap(objects: objects, name: "backstage-\(app.key.pid)") {
            case .failure(let why):
                fail(app, why.description)
                return
            case .success(let made):
                app.tapID = made.tap; app.aggID = made.aggregate; app.desc = made.desc
                if let f = HAL.tapFormat(made.tap) { app.sampleRate = f.mSampleRate; app.channels = Int(f.mChannelsPerFrame) }
                addFormatListener(app)
            }
        } else if let desc = app.desc {
            func update(_ list: [AudioObjectID]) -> OSStatus {
                desc.processes = list
                var a = HAL.address(kAudioTapPropertyDescription)
                var d: CATapDescription = desc
                return withUnsafeMutablePointer(to: &d) {
                    AudioObjectSetPropertyData(app.tapID, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
                }
            }
            var err = update(objects)
            if err != noErr {
                // A short-lived helper (every child of an inaudible launch is an audio client)
                // may be gone by now: retry with the clients that still exist.
                let present = Set(HAL.processObjects())
                let alive = objects.filter { present.contains($0) }
                if !alive.contains(object) || processBirth(pid) != birth {
                    _ = update(app.objects.filter { present.contains($0) })
                    log("audio: pid \(pid) exited before it could be added to the tap of pid \(app.key.pid)")
                    return
                }
                if alive.count < objects.count { objects = alive; err = update(objects) }
            }
            guard err == noErr else {
                fail(app, "couldn't add pid \(pid) to the app's tap: \(fourCC(err))")
                return
            }
        }
        let ms = (audioClock() - sight) * 1000
        app.objects = objects
        objectOwner[object] = app.key
        let member = AppKey(pid: pid, birth: birth)
        if !app.members.contains(member) { app.members.append(member) }
        app.sightToMuteMs.append((ms * 100).rounded() / 100)
        if app.sightToMuteMs.count > 16 { app.sightToMuteMs.removeFirst() }
        if app.state == "armed" { app.state = "muted" }
        app.version += 1
        log(String(format: "audio: muted pid %d (%@, audio object %u) %.1f ms after sight (before lookup %.1f ms, matching %.1f ms) at %.4f%@", pid, app.name, object, ms,
                   (lookupStarted - sight) * 1000, (matched - lookupStarted) * 1000, audioClock(),
                   pid == app.key.pid ? "" : " as a helper of pid \(app.key.pid)"))
        addRunningListener(app, object)
        publishCrashTable()
        if wasPlaying && audioClock() - restartedAt < 10 {
            // Apps resume by themselves after a coreaudiod restart; the gap was already audible.
            log("audio: pid \(pid) was playing again after the coreaudiod restart when re-tapped")
        } else if wasPlaying {
            fail(app, "pid \(pid) was already playing audio when backstage first saw it, so some of it was audible")
            return
        }
        if HAL.isRunningOutput(object) {
            log(String(format: "audio: pid %d started output during the %.1f ms tap setup; up to that much may have been audible", pid, ms))
        }
        prepareIO(app)
        evaluateIO(app)
    }

    private func addRunningListener(_ app: AppTap, _ object: AudioObjectID) {
        let key = app.key
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let app = self.apps[key] else { return }
            self.evaluateIO(app)
        }
        var a = HAL.address(kAudioProcessPropertyIsRunning)
        if AudioObjectAddPropertyListenerBlock(object, &a, tapQueue, block) == noErr { app.listeners.append((object, a, block)) }
    }

    private func addFormatListener(_ app: AppTap) {
        let key = app.key
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let app = self.apps[key] else { return }
            self.formatChanged(app)
        }
        var a = HAL.address(kAudioTapPropertyFormat)
        if AudioObjectAddPropertyListenerBlock(app.tapID, &a, tapQueue, block) == noErr { app.listeners.append((app.tapID, a, block)) }
    }

    /// The tap's format changed (an output device change): restart IO with a fresh ring.
    private func formatChanged(_ app: AppTap) {
        guard let f = HAL.tapFormat(app.tapID), f.mSampleRate != app.sampleRate || Int(f.mChannelsPerFrame) != app.channels else { return }
        log("audio: tap format of pid \(app.key.pid) changed to \(f.mSampleRate) Hz, \(f.mChannelsPerFrame) ch; restarting IO")
        stopIO(app)
        dismantleIO(app)
        app.sampleRate = f.mSampleRate
        app.channels = Int(f.mChannelsPerFrame)
        app.version += 1
        prepareIO(app)
    }

    /// Create the IOProc (no IO yet) when measuring is permitted. The first IOProc on a tap
    /// aggregate is where macOS asks for System Audio Recording, so it's never attempted
    /// without the grant: only `doctor` may raise that prompt.
    private func prepareIO(_ app: AppTap) {
        guard app.metered, capturePermitted, app.tapID != 0, app.ioProc == nil, !app.ioProcRequested else { return }
        guard let meter = app.meter ?? MeterBox(channels: UInt32(max(app.channels, 1))) else { return }
        app.meter = meter
        bs_meter_set_loud_threshold(meter.pointer, Float(pow(10, audioFloorDb / 20) / app.gain))
        app.ioProcRequested = true
        let aggregate = app.aggID, key = app.key
        ioSetupQueue.async { [self] in
            guard tapQueue.sync(execute: { apps[key]?.meter === meter && apps[key]?.aggID == aggregate }) else { return }
            var proc: AudioDeviceIOProcID?
            let ioproc: AudioDeviceIOProc = { device, now, input, inputTime, output, outputTime, client in
                bs_meter_ioproc(device, now, input, inputTime, output, outputTime, client)
            }
            let err = AudioDeviceCreateIOProcID(aggregate, ioproc, UnsafeMutableRawPointer(meter.pointer), &proc)
            let createdProc = proc
            tapQueue.async { [self, proc = createdProc] in
                guard let app = apps[key], app.aggID == aggregate, app.meter === meter else {
                    if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
                    return
                }
                app.ioProcRequested = false
                guard err == noErr, let proc else {
                    if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
                    self.log("audio: couldn't create the IOProc for pid \(key.pid): \(fourCC(err)) (muted, but not measured)")
                    return
                }
                app.ioProc = proc
                self.evaluateIO(app)
            }
        }
    }

    /// IO runs only while one of the app's processes runs output: the system's recording
    /// indicator stays off otherwise. Started from the is-running listener (measured to capture
    /// the first buffer), with the 50 ms timer as a backup; stopped 1 s after output stops.
    private func evaluateIO(_ app: AppTap) {
        guard app.tapID != 0 else { return }
        guard app.metered, capturePermitted else { if app.ioRunning { stopIO(app) }; return }
        let running = app.objects.contains { objectOwner[$0] != nil && HAL.isRunningOutput($0) }
        if running {
            app.ioStopAt = nil
            if !app.ioRunning { startIO(app) }
        } else if app.ioRunning {
            let now = audioClock()
            if let at = app.ioStopAt { if now >= at { stopIO(app) } } else { app.ioStopAt = now + 1 }
        }
    }

    private func startIO(_ app: AppTap) {
        guard let proc = app.ioProc, let meter = app.meter, app.sampleRate > 0, app.channels > 0 else { return }
        refreshGain(app)
        if app.ring == nil, let ring = RingBox(url: AudioFiles.ring(app.key.pid, app.key.birth), sampleRate: app.sampleRate,
                                                channels: app.channels, gain: app.gain) {
            app.ring = ring
            meter.pointer.pointee.ring = ring.header
            meter.pointer.pointee.ringData = ring.data
            meter.pointer.pointee.channels = UInt32(app.channels)
        } else if let ring = app.ring {
            // Keep the ring a continuous timeline: the pause becomes silence.
            let nowTicks = mach_absolute_time()
            let gap = hostTicksToSeconds(nowTicks) - ring.header.pointee.endUptime
            if ring.header.pointee.framesWritten > 0, gap > 0 {
                bs_ring_fill_silence(meter.pointer, UInt64(min(gap, 15) * app.sampleRate), nowTicks)
            }
        }
        let started = audioClock()
        let err = AudioDeviceStart(app.aggID, proc)
        guard err == noErr else {
            log("audio: couldn't start IO for pid \(app.key.pid): \(fourCC(err))")
            return
        }
        app.ioRunning = true
        app.version += 1
        log(String(format: "audio: IO on for pid %d (start took %.1f ms)", app.key.pid, (audioClock() - started) * 1000))
    }

    private func stopIO(_ app: AppTap) {
        guard app.ioRunning, let proc = app.ioProc else { return }
        AudioDeviceStop(app.aggID, proc)
        app.ioRunning = false
        app.ioStopAt = nil
        app.version += 1
        log("audio: IO off for pid \(app.key.pid)")
    }

    private func dismantleIO(_ app: AppTap) {
        if let proc = app.ioProc { AudioDeviceDestroyIOProcID(app.aggID, proc) }
        app.ioProc = nil
        app.ioProcRequested = false
        app.meter = nil
        if let ring = app.ring { try? FileManager.default.removeItem(at: ring.url) }
        app.ring = nil
    }

    /// Levels are compensated for the output device: a stereo mixdown tap averages a device's
    /// odd and even channels, so a stereo sound on 2 of N channels reads 20·log10(2/N) low
    /// (measured: -14.0 dB on 10 channels). Gain N/2 restores it for stereo content (the usual
    /// AUHAL/AVAudioEngine mapping); content spread over more channels then reads high.
    private func refreshGain(_ app: AppTap) {
        let widest = app.objects.filter { objectOwner[$0] != nil }
            .flatMap { HAL.outputDevices(of: $0) }
            .map { HAL.channels($0, input: false) }.max() ?? 2
        let n = max(widest, 2)
        guard n != app.outputChannels else { return }
        app.outputChannels = n
        if let meter = app.meter {
            bs_meter_set_loud_threshold(meter.pointer, Float(pow(10, audioFloorDb / 20) / app.gain))
        }
        app.ring?.header.pointee.levelGain = app.gain
        app.version += 1
    }

    private func fail(_ app: AppTap, _ why: String) {
        guard app.state != "failed" else { return }
        app.state = "failed"
        app.reason = why
        app.version += 1
        log("audio: FAILED for pid \(app.key.pid) (\(app.name)): \(why); quitting it")
        guard !app.quitRequested else { return }
        app.quitRequested = true
        let registered = registry.contains { $0.pid == app.key.pid && $0.birth == app.key.birth }
        for m in app.members { quit(m.pid, m.birth, registered && m == app.key) }
        // Publish now: `launch` may be waiting on this app.
        let status = AudioAppStatus(pid: app.key.pid, birth: app.key.birth, name: app.name, session: app.session, tap: "failed",
                                    reason: why, processes: app.pids, ioRunning: false, playing: false, peakDb: nil, rmsDb: nil,
                                    sampleRate: nil, channels: nil, outputChannels: nil, levelGainDb: nil, floorDb: audioFloorDb,
                                    time: audioClock(), sounds: [], sightToMuteMs: app.sightToMuteMs, ring: nil, launch: app.launchID,
                                    metered: app.metered)
        try? writePrivateJSON(AudioFiles.status(app.key.pid, app.key.birth), status)
    }

    /// Destroy an app's tap. Only after its processes are gone, or on handover (`show`).
    private func destroy(_ app: AppTap, keepFile: Bool, why: String) {
        stopIO(app)
        for (object, a, block) in app.listeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(object, &a, tapQueue, block)
        }
        app.listeners = []
        dismantleIO(app)
        if app.aggID != 0 { AudioHardwareDestroyAggregateDevice(app.aggID); app.aggID = 0 }
        if app.tapID != 0 { AudioHardwareDestroyProcessTap(app.tapID); app.tapID = 0 }
        for o in app.objects where objectOwner[o] == app.key { objectOwner[o] = nil }
        apps[app.key] = nil
        let status = AudioFiles.status(app.key.pid, app.key.birth)
        if keepFile { failedFiles.append((status, audioClock() + 600)) } else { try? FileManager.default.removeItem(at: status) }
        if !app.objects.isEmpty { log("audio: removed the tap of pid \(app.key.pid) (\(why))") }
        publishCrashTable()
    }

    // MARK: timers and system events (tapQueue)

    private func tick() {
        guard !stopped else { return }
        let now = audioClock()
        for app in apps.values where app.tapID != 0 {
            evaluateIO(app)
            if app.ioRunning && now >= app.nextGainCheck { app.nextGainCheck = now + 1; refreshGain(app) }
        }
        if now >= nextLiveness {
            nextLiveness = now + 0.25
            for app in Array(apps.values) {
                if processBirth(app.key.pid) == app.key.birth { app.rootDiedAt = nil; continue }
                let died = app.rootDiedAt ?? now
                app.rootDiedAt = died
                let helpersAlive = app.members.dropFirst().contains { processBirth($0.pid) == $0.birth }
                if !helpersAlive || now - died > 3 { destroy(app, keepFile: app.state == "failed", why: "app exited") }
            }
            failedFiles.removeAll { file, deadline in
                guard now >= deadline else { return false }
                try? FileManager.default.removeItem(at: file)
                return true
            }
        }
        if now >= nextRescan {
            nextRescan = now + 0.5
            if !apps.isEmpty || !Launching.records().isEmpty { rescan() }
        }
    }

    /// coreaudiod restarted: every tap, aggregate and process object is gone, so the apps are
    /// audible until they reconnect and get new taps (untested: needs root).
    private func serviceRestarted() {
        guard !stopped else { return }
        log("audio: coreaudiod restarted; rebuilding every tap")
        restartedAt = audioClock()
        for app in apps.values {
            app.listeners = []
            app.ioProc = nil; app.ioProcRequested = false; app.ioRunning = false; app.ioStopAt = nil
            app.tapID = 0; app.aggID = 0; app.desc = nil
            app.objects = []
            dismantleIO(app)
            app.sampleRate = 0
            app.channels = 0
            if app.state == "muted" { app.state = "armed" }
            app.version += 1
        }
        objectOwner = [:]
        seen = []
        processListChanged()
    }

    private func publishCrashTable() {
        let keys = apps.values.flatMap { $0.members }
        let pids = keys.map { Int32($0.pid) }, births = keys.map { $0.birth }
        bs_crash_set(1, pids, births, Int32(keys.count))
    }

    // MARK: capture permission

    private func refreshCapture(initial: Bool = false) {
        let preflight = tccPreflight("kTCCServiceAudioCapture")
        workerQueue.async { [self] in
            guard tapQueue.sync(execute: { !stopped }) else { return }
            health.preflight = preflight
            var permitted: Bool
            if testMode == "no-capture" {
                health.capture = "not granted"; health.captureSource = "test override"; permitted = false
            } else if health.captureSource == "self-test" {
                permitted = health.capture == "granted"
            } else {
                permitted = preflight == 0
                health.capture = permitted ? "granted" : "not granted"
                health.captureSource = "preflight"
            }
            writeHealth()
            let hostName = health.host?.name ?? "the daemon's host"
            tapQueue.async { [self] in
                let changed = capturePermitted != permitted
                capturePermitted = permitted
                if changed || initial {
                    log("audio: measuring \(permitted ? "enabled" : "disabled") (System Audio Recording \(permitted ? "granted" : "not granted") to \(hostName))")
                }
                guard !stopped else { return }
                if permitted { for app in apps.values { prepareIO(app) } }
                else if changed { for app in apps.values { stopIO(app) } }
            }
        }
    }

    private func writeHealth() {
        health.updated = audioClock()
        try? writePrivateJSON(AudioFiles.health, health)
    }

    // MARK: self-test (ioSetupQueue)

    private func publishSelfTest(_ result: AudioSelfTestResult) {
        tapQueue.sync {
            guard !stopped else { return }
            try? writePrivateJSON(AudioFiles.selfTestResult(result.id), result)
        }
    }

    private func runSelfTest(_ id: String) {
        guard tapQueue.sync(execute: { !stopped }) else { return }
        var result = AudioSelfTestResult(id: id, state: "running")
        func write() { publishSelfTest(result) }
        func finish(_ captured: Bool, _ error: String?) {
            result.state = "done"; result.captured = captured; result.error = error
            result.permission = captured ? "granted" : "not granted"
            write()
            workerQueue.async { [self] in
                if testMode != "no-capture" {
                    health.capture = captured ? "granted" : "not granted"
                    health.captureSource = "self-test"
                }
                refreshCapture()
            }
            log("audio: self-test \(captured ? "captured the probe" : "did not capture the probe")\(result.levelDb.map { String(format: " at %.1f dBFS", $0) } ?? "")\(error.map { ": \($0)" } ?? "")")
        }
        write()
        if testMode == "no-capture" { finish(false, "measuring disabled (BACKSTAGE_TEST_AUDIO=no-capture)"); return }
        // Output-only: attaching IO to a device with inputs makes macOS ask for the Microphone.
        guard let device = HAL.outputOnlyDevice() else {
            finish(false, "no output-only audio device to play the probe on (a device with inputs would make macOS ask for the Microphone)")
            return
        }
        result.device = HAL.name(device); result.outputOnly = true
        let me = HAL.processObject(for: ownPid)
        guard case .success(let made) = makeTap(objects: [me], name: "backstage-selftest") else { finish(false, "couldn't create the self-test tap"); return }
        defer { AudioHardwareDestroyAggregateDevice(made.aggregate); AudioHardwareDestroyProcessTap(made.tap) }
        let tapRate = HAL.tapFormat(made.tap)?.mSampleRate ?? 0
        let rate = HAL.nominalRate(device)
        guard tapRate.isFinite, tapRate > 37_000, rate.isFinite, rate > 37_000 else {
            finish(false, "the current sample rates cannot represent the 18.5 kHz probe")
            return
        }
        let lock = NSLock()
        var detector = Goertzel(hz: 18500, rate: tapRate)
        var tapProc: AudioDeviceIOProcID?
        let promptQueue = DispatchQueue(label: "backstage.audio.prompt-watch")
        var prompting = result
        prompting.state = "prompting"
        let promptStatus = prompting
        let promptWatch = DispatchWorkItem { [weak self] in
            self?.publishSelfTest(promptStatus)
            self?.log("audio: self-test is waiting on a System Audio Recording prompt")
        }
        promptQueue.asyncAfter(deadline: .now() + 1, execute: promptWatch)
        let setupStart = audioClock()
        let err = AudioDeviceCreateIOProcIDWithBlock(&tapProc, made.aggregate, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = abl.first, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = Int(max(b.mNumberChannels, 1)), frames = Int(b.mDataByteSize) / 4 / ch
            lock.lock()
            for i in 0..<frames { detector.feed(d[i * ch]) }
            lock.unlock()
        }
        promptQueue.sync { promptWatch.cancel() }
        result.ioSetupMs = (audioClock() - setupStart) * 1000
        guard err == noErr, let tapProc else { finish(false, "IOProc on the tap failed: \(fourCC(err))"); return }
        defer { AudioDeviceDestroyIOProcID(made.aggregate, tapProc) }
        let tone = ProbeTone(hz: 18500, dbfs: -60, seconds: 0.5, rate: rate)
        var rendered = 0
        var outProc: AudioDeviceIOProcID?
        let outErr = AudioDeviceCreateIOProcIDWithBlock(&outProc, device, nil) { _, _, _, output, _ in
            let abl = UnsafeMutableAudioBufferListPointer(output)
            var frames = 0, base = 0
            for b in abl {
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(max(b.mNumberChannels, 1)); frames = Int(b.mDataByteSize) / 4 / ch
                for i in 0..<frames {
                    let s = tone.sample(rendered + i)
                    for c in 0..<ch { d[i * ch + c] = base + c < 2 ? s : 0 }
                }
                base += ch
            }
            rendered += frames
        }
        guard outErr == noErr, let outProc else { finish(false, "couldn't play the probe on \(HAL.name(device)): \(fourCC(outErr))"); return }
        defer { AudioDeviceDestroyIOProcID(device, outProc) }
        let tapStart = AudioDeviceStart(made.aggregate, tapProc)
        guard tapStart == noErr else { finish(false, "couldn't start the self-test tap: \(fourCC(tapStart))"); return }
        defer { AudioDeviceStop(made.aggregate, tapProc) }
        let outStart = AudioDeviceStart(device, outProc)
        guard outStart == noErr else { finish(false, "couldn't start the probe on \(HAL.name(device)): \(fourCC(outStart))"); return }
        usleep(700_000)
        AudioDeviceStop(device, outProc)
        usleep(50_000)
        lock.lock()
        let measured = detector.best
        lock.unlock()
        let n = max(HAL.channels(device, input: false), 2)
        let level = measured + (n > 2 ? 20 * log10(Double(n) / 2) : 0)
        result.levelDb = level
        let captured = abs(level - result.expectedDb) <= 3
        finish(captured, captured ? nil : (measured <= -150 ? "the tap delivered silence (permission not granted?)" : "the tap captured the probe at the wrong level"))
    }

    // MARK: worker (workerQueue, 20 Hz)

    private func workerTick() {
        workerTicks += 1
        let now = audioClock()
        let snaps: [TapSnapshot] = tapQueue.sync {
            apps.values.map { a in
                TapSnapshot(key: a.key, name: a.name, session: a.session, state: a.state, reason: a.reason, pids: a.pids,
                            ioRunning: a.ioRunning, sampleRate: a.sampleRate, channels: a.channels, outputChannels: a.outputChannels,
                            gain: a.gain, sightToMuteMs: a.sightToMuteMs, meter: a.meter, ring: a.ring?.url.path, launch: a.launchID,
                            metered: a.metered, version: a.version)
            }
        }
        var levels: [AudioLevelSample] = []
        for snap in snaps {
            let an = analyses[snap.key] ?? Analysis()
            analyses[snap.key] = an
            drain(snap, an)
            if let c = an.current, now - c.end >= audioSoundGap { close(an) }
            let playing = an.current != nil
            var recentPeak = 0.0, recentSquares = 0.0, recentFrames = 0
            var livePeak = 0.0, liveSquares = 0.0, liveFrames = 0
            for block in an.history where block.end >= now - 1 {
                recentPeak = max(recentPeak, block.peak)
                recentSquares += block.sumSquares
                recentFrames += block.frames
                if block.end >= now - 0.1 {
                    livePeak = max(livePeak, block.peak)
                    liveSquares += block.sumSquares
                    liveFrames += block.frames
                }
            }
            let peak = recentFrames > 0 ? recentPeak : nil
            let rms = recentFrames > 0 ? (recentSquares / Double(recentFrames)).squareRoot() : nil
            // Only measured apps drive the menu bar meter.
            if snap.state != "failed" && snap.metered {
                let liveRMS = liveFrames > 0 ? (liveSquares / Double(liveFrames)).squareRoot() : 0
                levels.append(AudioLevelSample(pid: snap.key.pid, name: snap.name, playing: playing,
                                               peakDb: Float(dB(livePeak)), rmsDb: Float(dB(liveRMS))))
            }
            let active = snap.ioRunning || playing
            let changed = snap.version != an.lastVersion || playing != an.lastPlaying || snap.ioRunning != an.lastIO
                || (peak == nil) != (an.lastPeak == nil)
            guard snap.state != "failed" || snap.version != an.lastVersion else { continue }
            if changed || (active && now - an.lastPublished >= 0.1) {
                var sounds = an.sounds
                if let c = an.current {
                    sounds.append(AudioSound(start: c.start, seconds: max(0, c.end - c.start), peakDb: dB(c.peak),
                                             rmsDb: dB(c.frames > 0 ? (c.sumSquares / Double(c.frames)).squareRoot() : 0), ongoing: true))
                }
                let status = AudioAppStatus(pid: snap.key.pid, birth: snap.key.birth, name: snap.name, session: snap.session,
                                            tap: snap.state, reason: snap.reason, processes: snap.pids, ioRunning: snap.ioRunning,
                                            playing: playing, peakDb: peak.map(dB), rmsDb: rms.map(dB),
                                            sampleRate: snap.sampleRate > 0 ? snap.sampleRate : nil, channels: snap.channels > 0 ? snap.channels : nil,
                                            outputChannels: snap.outputChannels, levelGainDb: 20 * log10(snap.gain), floorDb: audioFloorDb,
                                            time: now, sounds: Array(sounds.suffix(16)), sightToMuteMs: snap.sightToMuteMs, ring: snap.ring,
                                            launch: snap.launch, metered: snap.metered)
                // A destroyed tap's file must not come back: write on the tap queue, only for apps
                // still there.
                guard tapQueue.sync(execute: {
                    guard apps[snap.key]?.version == snap.version else { return false }
                    try? writePrivateJSON(AudioFiles.status(snap.key.pid, snap.key.birth), status)
                    return true
                }) else { continue }
                an.lastPublished = now; an.lastVersion = snap.version; an.lastPlaying = playing; an.lastIO = snap.ioRunning; an.lastPeak = peak
            }
        }
        let present = Set(snaps.map { $0.key })
        analyses = analyses.filter { present.contains($0.key) }
        levelLock.lock(); levelCache = levels; levelLock.unlock()
        if workerTicks % 5 == 0 { pollSelfTestRequests() }
        if workerTicks % 100 == 0 { refreshCapture() }
    }

    private func drain(_ snap: TapSnapshot, _ an: Analysis) {
        guard let meter = snap.meter, snap.sampleRate > 0 else { return }
        if an.meter !== meter { an.meter = meter; an.blocksRead = 0 }
        let written = bs_meter_blocks_written(meter.pointer)
        if written - an.blocksRead > UInt64(BS_METER_BLOCKS) { an.blocksRead = written - UInt64(BS_METER_BLOCKS) }
        let floor = pow(10, audioFloorDb / 20)
        while an.blocksRead < written {
            let b = bs_meter_block(meter.pointer, an.blocksRead)
            an.blocksRead += 1
            guard b.frames > 0 else { continue }
            let start = hostTicksToSeconds(b.hostTime), end = start + Double(b.frames) / snap.sampleRate
            let peak = Double(b.peak) * snap.gain
            let sumSquares = b.sumSquares * snap.gain * snap.gain
            an.history.append((start, end, peak, sumSquares, Int(b.frames)))
            if b.firstLoud >= 0 || peak >= floor {
                let s = start + Double(max(b.firstLoud, 0)) / snap.sampleRate
                let e = start + Double(b.lastLoud >= 0 ? b.lastLoud + 1 : Int32(b.frames)) / snap.sampleRate
                if let c = an.current, s - c.end < audioSoundGap {
                    an.current = (c.start, max(c.end, e), max(c.peak, peak), c.sumSquares + an.pendingSquares + sumSquares,
                                  c.frames + an.pendingFrames + Int(b.frames))
                    an.pendingSquares = 0; an.pendingFrames = 0
                } else {
                    if an.current != nil { close(an) }
                    an.current = (s, e, peak, sumSquares, Int(b.frames))
                }
            } else if let c = an.current {
                if end - c.end >= audioSoundGap { close(an) }
                else { an.pendingSquares += sumSquares; an.pendingFrames += Int(b.frames) }
            }
        }
        let cutoff = audioClock() - 1.5
        if let i = an.history.firstIndex(where: { $0.end >= cutoff }) { an.history.removeFirst(i) } else { an.history.removeAll() }
    }

    private func close(_ an: Analysis) {
        guard let c = an.current else { return }
        an.sounds.append(AudioSound(start: c.start, seconds: max(0, c.end - c.start), peakDb: dB(c.peak),
                                    rmsDb: dB(c.frames > 0 ? (c.sumSquares / Double(c.frames)).squareRoot() : 0), ongoing: false))
        if an.sounds.count > 16 { an.sounds.removeFirst(an.sounds.count - 16) }
        an.current = nil
        an.pendingSquares = 0; an.pendingFrames = 0
    }

    private func pollSelfTestRequests() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: AudioFiles.dir.path) else { return }
        for n in names where n.hasPrefix("selftest-") && n.hasSuffix(".request") {
            let id = String(n.dropFirst("selftest-".count).dropLast(".request".count))
            try? FileManager.default.removeItem(at: AudioFiles.dir.appendingPathComponent(n))
            ioSetupQueue.async { [weak self] in self?.runSelfTest(id) }
        }
    }

    // MARK: AudioLevelSource (main thread, cheap)

    func currentLevels() -> [AudioLevelSample] {
        levelLock.lock(); defer { levelLock.unlock() }
        return levelCache
    }
}

private struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

private func dB(_ x: Double) -> Double { x > 0 ? max(20 * log10(x), -200) : -200 }
