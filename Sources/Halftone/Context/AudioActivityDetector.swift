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

    private(set) var micPIDs: Set<pid_t> = []
    private(set) var outputPIDs: Set<pid_t> = []
    /// Bundle ID per audio-active PID (helpers keep their own IDs).
    private(set) var bundleIDs: [pid_t: String] = [:]
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
    func _testSetState(micPIDs: Set<pid_t>, outputPIDs: Set<pid_t>) {
        self.micPIDs = micPIDs
        self.outputPIDs = outputPIDs
        notify()
    }
    func _testClearState() {
        micPIDs = []; outputPIDs = []; bundleIDs = [:]
        notify()
    }
#endif

    /// Bundle-ID prefixes whose "input running" is meaningless chatter:
    /// virtual audio drivers pin input open forever, and always-listening
    /// dictation daemons (Wispr Flow) grab the mic without being a call.
    /// Overridable: defaults write me.aniket.halftone audioIgnoredBundlePrefixes -array ...
    private var ignoredBundlePrefixes: [String] {
        (Defaults.store.array(forKey: "audioIgnoredBundlePrefixes") as? [String]) ?? [
            "com.rogueamoeba.",
            "audio.existential.BlackHole",
            "com.electron.wispr-flow",
        ]
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

    private func start() {
        guard !started else { return }
        started = true
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listener)
        refresh()
    }

    private func stop() {
        guard started else { return }
        started = false
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listener)
        debounce.cancel()
        syncObjectListeners(to: [])
        micPIDs = []; outputPIDs = []
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

        // 1. Fetch process object list
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size) == noErr,
            size > 0 else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &objects) == noErr
        else { return }

        // 2. Diff per-object listeners against the fresh list
        syncObjectListeners(to: Set(objects))

        // 3. Read state. Flags first: bundle ID is a CFString allocation and
        // only matters for the 0-3 objects actually running.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var newMic: Set<pid_t> = []
        var newOut: Set<pid_t> = []
        var newBundles: [pid_t: String] = [:]
        for obj in objects {
            let inp = readFlag(obj, &inputAddr)
            let out = readFlag(obj, &outputAddr)
            guard inp || out else { continue }
            let pid = readPID(obj)
            guard pid > 0, pid != ownPID else { continue }
            let bid = readBundleID(obj)
            if let bid, ignoredBundlePrefixes.contains(where: { bid.hasPrefix($0) }) { continue }
            if inp { newMic.insert(pid) }
            if out { newOut.insert(pid) }
            if let bid { newBundles[pid] = bid }
        }

        if newMic != micPIDs || newOut != outputPIDs {
            micPIDs = newMic
            outputPIDs = newOut
            bundleIDs = newBundles
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

/// "Someone is capturing the microphone" — the strongest meeting/call signal.
@MainActor
final class MicDetector: ContextDetector {
    let flag = ContextFlag.micInUse
    var onChange: (() -> Void)?
    private(set) var isDetected = false
    private var running = false

    private var observerID: UUID?

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
        callPIDs = []
        isDetected = false
    }

    /// PIDs that held the mic during this call session. A mute releases the
    /// mic while the app keeps producing output (you still hear the call);
    /// the call is over only when the app's whole audio session ends. Field
    /// bug: a 10s linger after mute fired a long break MID-CALL.
    private var callPIDs: Set<pid_t> = []

#if DEBUG
    func _testRecheck() { recheck() }
#endif

    private func recheck() {
        let monitor = AudioProcessMonitor.shared
        if !monitor.micPIDs.isEmpty {
            callPIDs = monitor.micPIDs
        } else {
            // Mic gone: the call survives while any call app still outputs.
            callPIDs = callPIDs.intersection(monitor.outputPIDs)
        }
        let now = !monitor.micPIDs.isEmpty || !callPIDs.isEmpty
        if now != isDetected {
            isDetected = now
            onChange?()
        }
    }
}
