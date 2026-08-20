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

    /// Bundle-ID prefixes whose "input running" is meaningless chatter
    /// (virtual audio drivers pin input open forever).
    private let ignoredBundlePrefixes = ["com.rogueamoeba.", "audio.existential.BlackHole"]

    private var started = false
    private let queue = DispatchQueue(label: "halftone.audio-monitor", qos: .utility)
    private var listedObjects: [AudioObjectID] = []
    private var debounce: DispatchWorkItem?

    private var systemListenerInstalled = false
    private lazy var listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleRefresh()
    }
    private lazy var stateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleRefresh()
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
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listListener)
        systemListenerInstalled = true
        refresh()
    }

    private func stop() {
        guard started else { return }
        started = false
        if systemListenerInstalled {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listListener)
            systemListenerInstalled = false
        }
        detachObjectListeners()
        micPIDs = []; outputPIDs = []
        notify()
    }

    private func detachObjectListeners() {
        for obj in listedObjects {
            AudioObjectRemovePropertyListenerBlock(obj, &inputAddr, queue, stateListener)
            AudioObjectRemovePropertyListenerBlock(obj, &outputAddr, queue, stateListener)
        }
        listedObjects = []
    }

    private nonisolated func scheduleRefresh() {
        Task { @MainActor in
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
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

        // 2. Re-install per-object listeners on the fresh list
        detachObjectListeners()
        for obj in objects {
            AudioObjectAddPropertyListenerBlock(obj, &inputAddr, queue, stateListener)
            AudioObjectAddPropertyListenerBlock(obj, &outputAddr, queue, stateListener)
        }
        listedObjects = objects

        // 3. Read state
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var newMic: Set<pid_t> = []
        var newOut: Set<pid_t> = []
        var newBundles: [pid_t: String] = [:]
        for obj in objects {
            let pid = readPID(obj)
            guard pid > 0, pid != ownPID else { continue }
            let bid = readBundleID(obj)
            if let bid, ignoredBundlePrefixes.contains(where: { bid.hasPrefix($0) }) { continue }
            let inp = readFlag(obj, &inputAddr)
            let out = readFlag(obj, &outputAddr)
            if inp { newMic.insert(pid) }
            if out { newOut.insert(pid) }
            if (inp || out), let bid { newBundles[pid] = bid }
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
        isDetected = false
    }

    private func recheck() {
        let now = !AudioProcessMonitor.shared.micPIDs.isEmpty
        if now != isDetected {
            isDetected = now
            onChange?()
        }
    }
}
