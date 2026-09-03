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
        // Apple's speech stack (Siri readiness, dictation) captures the mic
        // for seconds at a time after boot and never produces output. Field
        // bug: it seeded a phantom call every morning.
        "com.apple.CoreSpeech",
        "com.apple.siri",
        "com.apple.SpeechRecognition",
        "com.apple.assistant",
    ]

#if DEBUG
    static var _testBuiltInIgnoredPrefixes: [String] { builtInIgnoredPrefixes }
#endif

    private func currentIgnoredPrefixes() -> [String] {
        let user = (Defaults.store.array(forKey: "audioIgnoredBundlePrefixes") as? [String]) ?? []
        return Self.builtInIgnoredPrefixes + user
    }

    private var started = false
    private let queue = DispatchQueue(label: "halftone.audio-monitor", qos: .utility)
    private var listedObjects: Set<AudioObjectID> = []
    private let debounce = Debouncer(delay: 0.3)

    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Trace.mark("audio.event")
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
        // Mark stopped before cancelling so a late listener no-ops.
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

        // A transient coreaudiod failure must not freeze stale PID sets:
        // re-arm and retry.
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

        if newMic != micPIDs || newOut != outputPIDs || newBundles != bundleIDs
            || newAnonymous != anonymousPIDs {
            micPIDs = newMic
            outputPIDs = newOut
            bundleIDs = newBundles
            anonymousPIDs = newAnonymous
            Trace.mark("audio.refresh", "mic=\(newMic.sorted()) out=\(newOut.sorted())")
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
        // Create Rule: the returned CFString is +1 and WE must release it.
        // Bridging with `as String?` alone leaked one CFString per read
        // (28k leaks over three days of uptime in the field).
        var unmanaged: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let unmanaged else { return nil }
        let s = unmanaged.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    private func readFlag(_ obj: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}

/// One call's lifecycle, driven by evidence:
/// - Seeding: same named PID on the mic across observations spanning
///   minSeedDuration (blips and anonymous helpers cannot seed), AND its app
///   family is producing output. A call is two-way audio; speech
///   recognition and dictation capture the mic with nothing coming back.
/// - Mute survivorship: seeded PIDs must keep outputting under the bundle ID
///   captured at seed.
/// - TTL: no mic re-touch within maxMuteSurvival ends the session.
/// - Ceiling: continuous mic past maxContinuousDuration is not a call.
struct CallSession {
    static let minSeedDuration: TimeInterval = 2
    /// A muted call must re-touch the mic within this window, measured from
    /// the observed mute. Browser helpers multiplex tabs, so same-PID output
    /// alone is weak evidence; but real group-call mutes routinely run long,
    /// so the window must not truncate them.
    static let maxMuteSurvival: TimeInterval = 10 * 60
    /// Continuous mic past this is a stuck tab, not a meeting.
    static let maxContinuousDuration: TimeInterval = 2 * 60 * 60

    /// pid -> bundle ID captured at seed time.
    private(set) var participants: [pid_t: String] = [:]
    private var lastMicTouch = Date.distantPast

    /// Mic-capture start times for not-yet-seeded candidates.
    private var candidates: [pid_t: Date] = [:]

    var isLive: Bool { !participants.isEmpty }

    /// Bundle IDs sustaining the session; every call must be nameable.
    var participantBundleIDs: [String] { Array(Set(participants.values)).sorted() }

    /// The first observation where a participant was seeded.
    private var sessionStartedAt: Date?
    /// When the mic was first OBSERVED gone while the session lived. The TTL
    /// measures from here; measuring from the last event killed quiet steady
    /// calls at the mute instant (stale lastMicTouch).
    private var muteObservedAt: Date?
    /// PIDs expired by the continuous-duration ceiling. Quarantined from
    /// seeding until they release the mic (otherwise the stuck tab re-seeds
    /// within a second and the ceiling never actually ends the hold).
    private var quarantined: Set<pid_t> = []

    /// When the mic was last observed released while a session lived. Lets
    /// the detector poll fast right after a hangup and slow down later.
    var micReleasedAt: Date? { muteObservedAt }

    /// Same app family: identical, or one bundle ID prefixes the other
    /// (com.brave.Browser.helper ~ com.brave.Browser).
    static func sameFamily(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Feed one monitor observation. Returns true if liveness changed.
    mutating func observe(micPIDs: Set<pid_t>,
                          outputPIDs: Set<pid_t>,
                          bundleIDs: [pid_t: String],
                          anonymousPIDs: Set<pid_t>,
                          now: Date = Date()) -> Bool {
        let wasLive = isLive

        // Quarantine lifts only when the stuck PID finally releases the mic.
        quarantined.formIntersection(micPIDs)

        // 1. Candidate tracking: named PIDs currently on the mic.
        let seedable = micPIDs.subtracting(anonymousPIDs).subtracting(quarantined)
        candidates = candidates.filter { seedable.contains($0.key) }
        for pid in seedable where candidates[pid] == nil {
            candidates[pid] = now
        }

        // 2. Seed: candidates that have held the mic long enough AND whose
        // app family is also producing output. One-way capture is speech
        // recognition, not a call.
        let outputBundles = outputPIDs.compactMap { bundleIDs[$0] }
        for (pid, since) in candidates where now.timeIntervalSince(since) >= Self.minSeedDuration {
            guard let bid = bundleIDs[pid] else { continue }
            let twoWay = outputPIDs.contains(pid)
                || outputBundles.contains { Self.sameFamily($0, bid) }
            guard twoWay else { continue }
            if participants.isEmpty { sessionStartedAt = now }
            participants[pid] = bid
        }

        // 3. Track the observed mute boundary.
        if !micPIDs.isEmpty {
            if !participants.isEmpty { lastMicTouch = now }
            muteObservedAt = nil
        } else if isLive, muteObservedAt == nil {
            muteObservedAt = now
        }

        // 4. Survivorship: participants must keep outputting under the SAME
        // identity; otherwise they leave the session.
        if micPIDs.isEmpty {
            participants = participants.filter { pid, seedBundle in
                outputPIDs.contains(pid) && bundleIDs[pid] == seedBundle
            }
        }

        // 5. Mute TTL, measured from the observed mute.
        if isLive, let muted = muteObservedAt,
           now.timeIntervalSince(muted) > Self.maxMuteSurvival {
            participants = [:]
        }

        // 6. Continuous-duration ceiling: expire AND quarantine, or the
        // stuck PID re-seeds within a second and the hold never drops.
        if isLive, let start = sessionStartedAt,
           now.timeIntervalSince(start) > Self.maxContinuousDuration,
           !micPIDs.isEmpty {
            quarantined.formUnion(participants.keys)
            candidates = candidates.filter { !quarantined.contains($0.key) }
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
        muteObservedAt = nil
        quarantined = []
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
    private var pollInterval: TimeInterval?

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
        pollInterval = nil
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

        // Two windows need self-observation (CoreAudio stays silent between
        // state changes): an unseeded candidate (fast poll, so a 2s seed can
        // be observed before release) and a muted survivorship. Right after
        // the mic drops the poll is fast, because a hangup ends output within
        // seconds and every extra poll interval lands on the user as lag;
        // after a minute it is a mute, so the poll backs off to 30s.
        let wantedInterval: TimeInterval?
        if !monitor.micPIDs.isEmpty && !session.isLive {
            wantedInterval = 1
        } else if session.isLive && monitor.micPIDs.isEmpty {
            let sinceRelease = session.micReleasedAt.map { now.timeIntervalSince($0) } ?? 0
            wantedInterval = sinceRelease < 60 ? 2 : 30
        } else {
            wantedInterval = nil
        }
        if wantedInterval != pollInterval {
            seedTimer.stop()
            pollInterval = wantedInterval
            if let iv = wantedInterval {
                seedTimer.start(interval: iv, leeway: .milliseconds(Int(iv * 100))) { [weak self] in
                    self?.recheck()
                }
            }
        }

        if changed || session.isLive != isDetected {
            isDetected = session.isLive
            Trace.mark("mic.detected", "\(isDetected) participants=\(session.participantBundleIDs)")
            onChange?()
        }
    }
}
