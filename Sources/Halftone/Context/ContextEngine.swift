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

    /// Start/stop each detector to match its toggle. Idempotent; called on
    /// every preference change so toggles take effect immediately.
    private func applyToggles() {
        for (detector, enabled) in all {
            if prefs[keyPath: enabled] { detector.start() } else { detector.stop() }
        }
        deepFocus.listChanged() // hold-list edits apply immediately too
        recompute()
    }

    private func recompute() {
        var flags: Set<ContextFlag> = []
        for (detector, enabled) in all where prefs[keyPath: enabled] && detector.isDetected {
            flags.insert(detector.flag)
        }
        guard flags != activeFlags else { return }
        activeFlags = flags

        if !flags.isEmpty {
            // Condition active: hold, cancel any linger countdown.
            lingerTimer?.cancel(); lingerTimer = nil
            holdReasons = flags
            setHold(true)
        } else {
            // guard above means hadFlags: keep holding through the linger.
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
#endif

    private func setHold(_ hold: Bool) {
        if hold != shouldHold { shouldHold = hold }
        onChange?() // reasons may change even when hold doesn't
    }
}
