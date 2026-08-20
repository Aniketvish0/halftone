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

    private var all: [(detector: any ContextDetector, enabled: () -> Bool)] {
        [
            (mic, { self.prefs.pauseOnMic }),
            (camera, { self.prefs.pauseOnCamera }),
            (screenCapture, { self.prefs.pauseOnScreenCapture }),
            (media, { self.prefs.pauseOnMedia }),
            (fullscreen, { self.prefs.pauseOnFullscreen }),
            (deepFocus, { self.prefs.pauseOnDeepFocusApps }),
        ]
    }

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
            if enabled() { detector.start() } else { detector.stop() }
        }
        deepFocus.listChanged() // hold-list edits apply immediately too
        recompute()
    }

    private func recompute() {
        var flags: Set<ContextFlag> = []
        for (detector, enabled) in all where enabled() && detector.isDetected {
            flags.insert(detector.flag)
        }
        guard flags != activeFlags else { return }

        let hadFlags = !activeFlags.isEmpty
        activeFlags = flags

        if !flags.isEmpty {
            // Condition active: hold, cancel any linger countdown.
            lingerTimer?.cancel(); lingerTimer = nil
            holdReasons = flags
            setHold(true)
        } else if hadFlags {
            // Conditions just cleared: keep holding through the linger window.
            startLinger()
        } else if lingerTimer == nil {
            holdReasons = []
            setHold(false)
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

    private func setHold(_ hold: Bool) {
        guard hold != shouldHold else {
            onChange?() // reasons may have changed even if hold didn't
            return
        }
        shouldHold = hold
        onChange?()
    }
}
