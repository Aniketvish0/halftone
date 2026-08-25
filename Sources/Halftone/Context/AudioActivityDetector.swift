import Foundation
import CoreAudio
import AppKit

/// Watches CoreAudio *process objects* (macOS 14.4+, public API, no TCC):
/// every process registered with the audio server exposes IsRunningInput
/// (capturing the mic) and IsRunningOutput (producing audio). Fully
/// event-driven via property listeners; near-zero CPU.
///
/// One shared engine feeds two logical detectors: `micInUse` and
/// `audioOutputActive` (the latter is combined with power assertions by
/// MediaPlaybackDetector to mean "video playing").
@MainActor
final class AudioProcessMonitor {
    static let shared = AudioProcessMonitor()

    /// PIDs currently capturing the mic (ignore-listed apps excluded).
    private(set) var micPIDs: Set<pid_t> = []
    /// PIDs currently producing audio output (ignore-listed apps excluded).
    private(set) var outputPIDs: Set<pid_t> = []
    /// Bundle ID per audio-active PID. nil-bundle processes (helpers, XPC,
    /// daemons) are NOT in this map but may appear in the PID sets.
    private(set) var bundleIDs: [pid_t: String] = [:]
    /// PIDs whose bundle ID could not be resolved. Untrusted for call
    /// SEEDING (the ignore list cannot vouch for them) but valid as output.
    private(set) var anonymousPIDs: Set<pid_t> = []

    private var observers: [UUID: () -> Void] = [:]

    func addObserver(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() { for block in observers.values { block() } }

#if DEBUG
    /// Test seams: inject monitor state without CoreAudio.
    func _testSetState(micPIDs: Set<pid_t>, outputPIDs: Set<pid_t>,
                       bundleIDs: [pid_t: String] = [:],
                       anonymousPIDs: Set<pid_t> = []) {
        self.micPIDs = micPIDs
        self.outputPIDs = outputPIDs
        self.bundleIDs = bundleIDs
        self.anonymousPIDs = anonymousPIDs
        notify()
    }
    func _testClearState() {
        micPIDs = []; outputPIDs = []; bundleIDs = [:]; anonymousPIDs = []
        notify()
    }
#endif

    /// Bundle-ID prefixes whose "input running" is meaningless chatter:
    /// virtual audio drivers pin input open forever, and always-listening
    /// dictation daemons (Wispr Flow) grab the mic without being a call.
    /// User additions are ADDITIVE to the built-ins:
    /// defaults write me.aniket.halftone audioIgnoredBundlePrefixes -array ...
    private static let builtInIgnoredPrefixes = [
        "com.rogueamoeba.",
        "audio.existential.BlackHole",
        "com.electron.wispr-flow",
    ]

    private func currentIgnoredPrefixes() -> [String] {
        let user = (Defaults.store.array(forKey: "audioIgnoredBundlePrefixes") as? [String]) ?? []
        return Self.builtInIgnoredPrefixes + user
    }

    private var started = false
    private let queue = DispatchQueue(label: "halftone.audio-monitor", qos: .utility)
    private var listedObjects: Set<AudioObjectID> = []
    private let debounce = Debouncer(delay: 0.3)

    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.debounce.schedule {
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var inputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var outputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private var refCount = 0

    /// Reference-counted: mic detector and media detector both retain us.
    func retainMonitor() {
        refCount += 1
        if refCount == 1 { start() }
    }

    func releaseMonitor() {
        refCount = max(0, refCount - 1)
        if refCount == 0 { stop() }
    }

    /// Ignore-list edits and toggle changes apply immediately, not at the
    /// next incidental CoreAudio event.
    func refreshNow() {
        guard started else { return }
        refresh()
    }

    private func start() {
        guard !started else { return }
        started = true
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listener)
        refresh()
    }

    private func stop() {
        guard started else { return }
        // Order matters: mark stopped BEFORE cancelling, so an in-flight
        // listener on the .utility queue that lands after cancel() schedules
        // a refresh that no-ops on the started guard instead of reviving.
        started = false
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listener)
        debounce.cancel()
        syncObjectListeners(to: [])
        micPIDs = []; outputPIDs = []; bundleIDs = [:]; anonymousPIDs = []
        notify()
    }

    /// Diffs listener registrations against the fresh object list. The naive
    /// remove-all/re-add-all costs 4 coreaudiod round-trips per object per
    /// refresh (hundreds during a call); the diff is zero in steady state.
    private func syncObjectListeners(to objects: Set<AudioObjectID>) {
        for obj in listedObjects.subtracting(objects) {
            AudioObjectRemovePropertyListenerBlock(obj, &inputAddr, queue, listener)
            AudioObjectRemovePropertyListenerBlock(obj, &outputAddr, queue, listener)
        }
        for obj in objects.subtracting(listedObjects) {
            AudioObjectAddPropertyListenerBlock(obj, &inputAddr, queue, listener)
            AudioObjectAddPropertyListenerBlock(obj, &outputAddr, queue, listener)
        }
        listedObjects = objects
    }

    private func refresh() {
        guard started else { return }

        // 1. Fetch process object list. A transient coreaudiod failure must
        // not freeze stale PID sets (a stale "call" persisted for minutes in
        // the field): re-arm the debounce and try again.
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size) == noErr,
            size > 0 else {
            debounce.schedule { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            return
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &objects) == noErr
        else {
            debounce.schedule { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            return
        }

        // 2. Diff per-object listeners against the fresh list
        syncObjectListeners(to: Set(objects))

        // 3. Read state. Flags first: bundle ID is a CFString allocation and
        // only matters for the 0-3 objects actually running.
        let ignored = currentIgnoredPrefixes()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var newMic: Set<pid_t> = []
        var newOut: Set<pid_t> = []
        var newBundles: [pid_t: String] = [:]
        var newAnonymous: Set<pid_t> = []
        for obj in objects {
            let inp = readFlag(obj, &inputAddr)
            let out = readFlag(obj, &outputAddr)
            guard inp || out else { continue }
            let pid = readPID(obj)
            guard pid > 0, pid != ownPID else { continue }
            if let bid = readBundleID(obj) {
                if ignored.contains(where: { bid.hasPrefix($0) }) { continue }
                newBundles[pid] = bid
            } else {
                // Unresolvable identity: the ignore list cannot vouch for it.
                // Tracked separately so call SEEDING can refuse it while
                // output accounting still counts it.
                newAnonymous.insert(pid)
            }
            if inp { newMic.insert(pid) }
            if out { newOut.insert(pid) }
        }

        if newMic != micPIDs || newOut != outputPIDs || newBundles != bundleIDs {
            micPIDs = newMic
            outputPIDs = newOut
            bundleIDs = newBundles
            anonymousPIDs = newAnonymous
            notify()
        }
    }

    private func readPID(_ obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid)
        return pid
    }

    private func readBundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let s = cf as String?, !s.isEmpty else { return nil }
        return s
    }

    private func readFlag(_ obj: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}

/// The lifecycle of one call: seeded by sustained mic capture, surviving
/// mutes while the same app keeps producing audio, ended by silence from
/// that app, a hard TTL, or the mic never having been genuinely held.
///
/// Evidence rules (each traces to a field bug):
/// - SEEDING requires the same PID to hold the mic across two consecutive
///   observations spanning >= minSeedDuration. One-frame touches (dictation
///   daemons, browser permission probes) latched permanent phantom calls.
/// - Only PIDs with a RESOLVED bundle ID can seed: the ignore list cannot
///   vouch for anonymous helpers, and they seeded phantoms through the
///   `if let` bypass.
/// - SURVIVING a mute requires the surviving output PID to still report the
///   bundle ID captured at seed time (kills PID reuse and cross-purpose
///   audio sustain).
/// - TTL: without a mic re-touch for maxMuteSurvival, the session ends.
///   No phantom outlives its evidence.
struct CallSession {
    static let minSeedDuration: TimeInterval = 2
    static let maxMuteSurvival: TimeInterval = 30 * 60
    /// No call runs for >2 hours of continuous mic without a single mute or
    /// break. A browser tab holding getUserMedia permanently (Dia/Arc pre-join
    /// preview, a stuck WebRTC session) is the field case. After this ceiling
    /// the session is expired, and the next mic release will not re-seed
    /// until a genuine new session begins.
    static let maxContinuousDuration: TimeInterval = 2 * 60 * 60

    /// pid -> bundle ID captured at seed time.
    private(set) var participants: [pid_t: String] = [:]
    private var lastMicTouch = Date.distantPast

    /// Mic-capture start times for not-yet-seeded candidates.
    private var candidates: [pid_t: Date] = [:]

    var isLive: Bool { !participants.isEmpty }

    /// Bundle IDs sustaining the session (for the menu's hold summary —
    /// a call must always be nameable; a nameless call was the field
    /// signature of the phantom bug).
    var participantBundleIDs: [String] { Array(Set(participants.values)).sorted() }

    /// The first observation where a participant was seeded.
    private var sessionStartedAt: Date?

    /// Feed one monitor observation. Returns true if liveness changed.
    mutating func observe(micPIDs: Set<pid_t>,
                          outputPIDs: Set<pid_t>,
                          bundleIDs: [pid_t: String],
                          anonymousPIDs: Set<pid_t>,
                          now: Date = Date()) -> Bool {
        let wasLive = isLive

        // 1. Candidate tracking: named PIDs currently on the mic.
        let seedable = micPIDs.subtracting(anonymousPIDs)
        candidates = candidates.filter { seedable.contains($0.key) }
        for pid in seedable where candidates[pid] == nil {
            candidates[pid] = now
        }

        // 2. Seed: candidates that have held the mic long enough.
        for (pid, since) in candidates where now.timeIntervalSince(since) >= Self.minSeedDuration {
            if let bid = bundleIDs[pid] {
                if participants.isEmpty { sessionStartedAt = now }
                participants[pid] = bid
            }
        }

        // 3. Mic touch refreshes the TTL.
        if !micPIDs.isEmpty && !participants.isEmpty {
            lastMicTouch = now
        }

        // 4. Survivorship: participants must keep outputting under the SAME
        // identity; otherwise they leave the session.
        if micPIDs.isEmpty {
            participants = participants.filter { pid, seedBundle in
                outputPIDs.contains(pid) && bundleIDs[pid] == seedBundle
            }
        }

        // 5. TTL: a muted "call" that hasn't touched the mic in
        // maxMuteSurvival is not a call.
        if isLive, now.timeIntervalSince(lastMicTouch) > Self.maxMuteSurvival {
            participants = [:]
        }

        // 6. Continuous-duration ceiling: a "call" with the mic held
        // continuously for > maxContinuousDuration is a stuck browser tab,
        // not a meeting.
        if isLive, let start = sessionStartedAt,
           now.timeIntervalSince(start) > Self.maxContinuousDuration,
           !micPIDs.isEmpty {
            participants = [:]
            sessionStartedAt = nil
        }

        if !isLive { lastMicTouch = .distantPast }
        return isLive != wasLive
    }

    mutating func reset() {
        participants = [:]
        candidates = [:]
        lastMicTouch = .distantPast
        sessionStartedAt = nil
    }
}

/// "Someone is on a call" — sustained mic capture, surviving mutes.
@MainActor
final class MicDetector: ContextDetector {
    let flag = ContextFlag.micInUse
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var session = CallSession()
    private var observerID: UUID?
    /// Re-observes shortly after a candidate appears so seeding does not
    /// wait for the next CoreAudio event (which may be the mic RELEASE).
    private let seedTimer = RepeatingPoller()

    /// Apps sustaining the current call, for the hold summary.
    var callParticipants: [String] { session.participantBundleIDs }

    func start() {
        guard observerID == nil else { return }
        AudioProcessMonitor.shared.retainMonitor()
        observerID = AudioProcessMonitor.shared.addObserver { [weak self] in
            self?.recheck()
        }
        recheck()
    }

    func stop() {
        guard let id = observerID else { return }
        AudioProcessMonitor.shared.removeObserver(id)
        AudioProcessMonitor.shared.releaseMonitor()
        observerID = nil
        seedTimer.stop()
        session.reset()
        isDetected = false
    }

#if DEBUG
    func _testRecheck(now: Date = Date()) { recheck(now: now) }
#endif

    private func recheck(now: Date = Date()) {
        let monitor = AudioProcessMonitor.shared
        let changed = session.observe(micPIDs: monitor.micPIDs,
                                      outputPIDs: monitor.outputPIDs,
                                      bundleIDs: monitor.bundleIDs,
                                      anonymousPIDs: monitor.anonymousPIDs,
                                      now: now)

        // A candidate needs a second observation >= minSeedDuration later to
        // seed; CoreAudio may stay silent until the mic releases. Poll once
        // per second only while an unseeded candidate exists.
        if !monitor.micPIDs.isEmpty && !session.isLive {
            seedTimer.start(interval: 1, leeway: .milliseconds(200)) { [weak self] in
                self?.recheck()
            }
        } else {
            seedTimer.stop()
        }

        if changed || session.isLive != isDetected {
            isDetected = session.isLive
            onChange?()
        }
    }
}
