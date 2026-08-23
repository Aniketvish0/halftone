import Foundation
import Observation

/// Composes all detectors into one answer: "should breaks be held right now,
/// and why?" Detectors start/stop live as the user flips toggles. After all
/// hold conditions clear, a configurable linger keeps breaks held a little
/// longer (meetings have silences; videos have chapter gaps).
@Observable
@MainActor
final class ContextEngine {
    /// Flags currently detected AND enabled by the user.
    private(set) var activeFlags: Set<ContextFlag> = []
    /// True while breaks should be held (active flags, or lingering after them).
    private(set) var shouldHold = false
    /// What the UI shows as the hold reason (kept during linger).
    private(set) var holdReasons: Set<ContextFlag> = []

    /// Menu-ready summary of the hold reasons.
    var holdReasonsSummary: String {
        let names = holdReasons.map(\.displayName).sorted().joined(separator: ", ")
        return names.isEmpty ? "recent activity" : names
    }

    var onChange: (() -> Void)?

    private let prefs = Preferences.shared
    private let mic = MicDetector()
    private let camera = CameraDetector()
    private let screenCapture = ScreenCaptureDetector()
    private let media = MediaPlaybackDetector()
    private let fullscreen = FullscreenDetector()
    private let deepFocus = DeepFocusAppDetector()

    private var lingerTimer: DispatchSourceTimer?

    /// Built once: detector paired with the preference that enables it.
    @ObservationIgnored
    private lazy var all: [(detector: any ContextDetector, enabled: KeyPath<Preferences, Bool>)] = [
        (mic, \.pauseOnMic),
        (camera, \.pauseOnCamera),
        (screenCapture, \.pauseOnScreenCapture),
        (media, \.pauseOnMedia),
        (fullscreen, \.pauseOnFullscreen),
        (deepFocus, \.pauseOnDeepFocusApps),
    ]

    init() {
        for (detector, _) in all {
            detector.onChange = { [weak self] in self?.recompute() }
        }
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyToggles() }
        }
        applyToggles()
    }

    /// True while media is detected playing, INDEPENDENT of whether the
    /// user wants video to hold breaks. Feeds idle suppression: "watching a
    /// video with hands off the keyboard is not away" must hold even when
    /// the Video playing hold-toggle is off. Reads through the detector
    /// table so test-installed detectors participate too.
    var isMediaPlaying: Bool {
        all.contains { $0.detector.flag == .mediaPlaying && $0.detector.isDetected }
    }

    /// True while ANY engagement signal is detected raw (call, camera,
    /// screen share, media), regardless of hold toggles. Feeds idle
    /// suppression: sitting still on a call is not being away. Fullscreen
    /// and focus apps are deliberately excluded — they say nothing about
    /// presence when the keyboard is untouched.
    var isEngaged: Bool {
        let engagementFlags: Set<ContextFlag> = [.micInUse, .cameraInUse,
                                                 .screenCaptured, .mediaPlaying]
        return all.contains { engagementFlags.contains($0.detector.flag) && $0.detector.isDetected }
    }

    /// Start/stop each detector to match its toggle. Idempotent; called on
    /// every preference change so toggles take effect immediately.
    private func applyToggles() {
        let engagementFlags: Set<ContextFlag> = [.micInUse, .cameraInUse,
                                                 .screenCaptured, .mediaPlaying]
        for (detector, enabled) in all {
            // Engagement detectors also power idle suppression ("on a call
            // with hands still is not away"), so they run when EITHER
            // consumer needs them; recompute still gates flags on the
            // hold-toggles alone.
            let needed = prefs[keyPath: enabled]
                || (engagementFlags.contains(detector.flag) && prefs.idleEnabled)
            if needed { detector.start() } else { detector.stop() }
        }
        deepFocus.listChanged() // hold-list edits apply immediately too
        // The user flipped a switch: that's an instruction, not an activity
        // ending. Release instantly instead of lingering.
        recompute(clearImmediately: true)
    }

    private func recompute(clearImmediately: Bool = false) {
        var flags: Set<ContextFlag> = []
        for (detector, enabled) in all where prefs[keyPath: enabled] && detector.isDetected {
            flags.insert(detector.flag)
        }
        let changed = flags != activeFlags
        activeFlags = flags

        if !flags.isEmpty {
            guard changed else { return }
            lingerTimer?.cancel(); lingerTimer = nil
            holdReasons = flags
            setHold(true)
        } else if clearImmediately {
            // A toggle flip is an instruction, not an activity ending:
            // release now, even mid-linger (when the flags diff is empty).
            guard shouldHold else { return }
            lingerTimer?.cancel(); lingerTimer = nil
            holdReasons = []
            setHold(false)
        } else if changed {
            // Activity ended on its own: keep holding through the linger
            // (calls have silences, videos have chapter gaps).
            startLinger()
        }
    }

    private func startLinger() {
        lingerTimer?.cancel()
        let linger = TimeInterval(prefs.contextLingerSec)
        guard linger > 0 else {
            holdReasons = []
            setHold(false)
            return
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + linger, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lingerTimer = nil
            // Only release if nothing re-triggered during the linger.
            if self.activeFlags.isEmpty {
                self.holdReasons = []
                self.setHold(false)
            }
        }
        t.resume()
        lingerTimer = t
    }

#if DEBUG
    /// Test seam: forces the hold state as if detectors had fired. Debug-only
    /// so no release-build caller can desync the engine from real detectors.
    func _testSetHold(_ hold: Bool, reasons: Set<ContextFlag> = [.micInUse]) {
        lingerTimer?.cancel(); lingerTimer = nil
        activeFlags = hold ? reasons : []
        holdReasons = hold ? reasons : []
        setHold(hold)
    }

    /// Test seam: a fake detector wired through the REAL toggle/recompute
    /// machinery (unlike _testSetHold, which bypasses it). `enabled` maps it
    /// to a real preference so preference flips exercise the real path.
    @MainActor
    final class _TestDetector: ContextDetector {
        let flag: ContextFlag
        var onChange: (() -> Void)?
        private(set) var isDetected = false
        private(set) var running = false
        private var wanted = false
        init(flag: ContextFlag) { self.flag = flag }
        // Like real detectors, start() re-reads current truth (the latched
        // `wanted`), so a simulate before start isn't silently dropped.
        func start() {
            running = true
            if wanted != isDetected { isDetected = wanted; onChange?() }
        }
        func stop() { running = false; isDetected = false }
        func simulate(detected: Bool) {
            wanted = detected
            isDetected = detected && running
            onChange?()
        }
    }

    /// Registers a fake detector bound to a preference key path, REPLACING
    /// the real detector for that flag. Appending instead of replacing left
    /// the real detector running alongside the fake, so real machine state
    /// (an actual fullscreen Space, actual playing audio) polluted tests.
    @discardableResult
    func _testInstallDetector(flag: ContextFlag, enabled: KeyPath<Preferences, Bool>) -> _TestDetector {
        for (detector, _) in all where detector.flag == flag {
            detector.stop()
        }
        all.removeAll { $0.detector.flag == flag }
        let d = _TestDetector(flag: flag)
        d.onChange = { [weak self] in self?.recompute() }
        all.append((d, enabled))
        applyToggles()
        return d
    }
#endif

    private func setHold(_ hold: Bool) {
        if hold != shouldHold { shouldHold = hold }
        onChange?() // reasons may change even when hold doesn't
    }
}
