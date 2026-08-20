import Foundation
import Observation

/// All user preferences. Single source of truth backed by UserDefaults.
/// Views bind to this; the engine re-reads on change notification.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()
    static let changed = Notification.Name("HalftonePreferencesChanged")

    private let d = Defaults.store

    private init() {
        d.register(defaults: [
            Key.shortIntervalMin: 20,
            Key.shortDurationSec: 20,
            Key.longIntervalMin: 60,
            Key.longDurationSec: 300,
            Key.warnLeadSec: 30,
            Key.playSounds: true,
            Key.showCountdownInMenuBar: true,
            Key.pauseOnMic: true,
            Key.pauseOnCamera: true,
            Key.pauseOnScreenCapture: true,
            Key.pauseOnMedia: true,
            Key.pauseOnFullscreen: true,
            Key.pauseOnDeepFocusApps: true,
            Key.contextLingerSec: 60,
            Key.idleEnabled: true,
            Key.idleThresholdSec: 180,
            Key.officeHoursEnabled: false,
            Key.officeStartMin: 9 * 60,
            Key.officeEndMin: 18 * 60,
            Key.officeDays: [2, 3, 4, 5, 6], // Mon-Fri (Calendar weekday numbers)
            Key.deepFocusApps: [String](),
        ])
        shortIntervalMin = d.integer(forKey: Key.shortIntervalMin)
        shortDurationSec = d.integer(forKey: Key.shortDurationSec)
        longIntervalMin = d.integer(forKey: Key.longIntervalMin)
        longDurationSec = d.integer(forKey: Key.longDurationSec)
        warnLeadSec = d.integer(forKey: Key.warnLeadSec)
        playSounds = d.bool(forKey: Key.playSounds)
        showCountdownInMenuBar = d.bool(forKey: Key.showCountdownInMenuBar)
        pauseOnMic = d.bool(forKey: Key.pauseOnMic)
        pauseOnCamera = d.bool(forKey: Key.pauseOnCamera)
        pauseOnScreenCapture = d.bool(forKey: Key.pauseOnScreenCapture)
        pauseOnMedia = d.bool(forKey: Key.pauseOnMedia)
        pauseOnFullscreen = d.bool(forKey: Key.pauseOnFullscreen)
        pauseOnDeepFocusApps = d.bool(forKey: Key.pauseOnDeepFocusApps)
        contextLingerSec = d.integer(forKey: Key.contextLingerSec)
        idleEnabled = d.bool(forKey: Key.idleEnabled)
        idleThresholdSec = d.integer(forKey: Key.idleThresholdSec)
        officeHoursEnabled = d.bool(forKey: Key.officeHoursEnabled)
        officeStartMin = d.integer(forKey: Key.officeStartMin)
        officeEndMin = d.integer(forKey: Key.officeEndMin)
        officeDays = Set((d.array(forKey: Key.officeDays) as? [Int]) ?? [2,3,4,5,6])
        deepFocusApps = Set((d.array(forKey: Key.deepFocusApps) as? [String]) ?? [])
    }

    private enum Key {
        static let shortIntervalMin = "shortIntervalMin"
        static let shortDurationSec = "shortDurationSec"
        static let longIntervalMin = "longIntervalMin"
        static let longDurationSec = "longDurationSec"
        static let warnLeadSec = "warnLeadSec"
        static let playSounds = "playSounds"
        static let showCountdownInMenuBar = "showCountdownInMenuBar"
        static let pauseOnMic = "pauseOnMic"
        static let pauseOnCamera = "pauseOnCamera"
        static let pauseOnScreenCapture = "pauseOnScreenCapture"
        static let pauseOnMedia = "pauseOnMedia"
        static let pauseOnFullscreen = "pauseOnFullscreen"
        static let pauseOnDeepFocusApps = "pauseOnDeepFocusApps"
        static let contextLingerSec = "contextLingerSec"
        static let idleEnabled = "idleEnabled"
        static let idleThresholdSec = "idleThresholdSec"
        static let officeHoursEnabled = "officeHoursEnabled"
        static let officeStartMin = "officeStartMin"
        static let officeEndMin = "officeEndMin"
        static let officeDays = "officeDays"
        static let deepFocusApps = "deepFocusApps"
    }

    var shortIntervalMin: Int { didSet { save(Key.shortIntervalMin, shortIntervalMin) } }
    var shortDurationSec: Int { didSet { save(Key.shortDurationSec, shortDurationSec) } }
    var longIntervalMin: Int { didSet { save(Key.longIntervalMin, longIntervalMin) } }
    var longDurationSec: Int { didSet { save(Key.longDurationSec, longDurationSec) } }
    var warnLeadSec: Int { didSet { save(Key.warnLeadSec, warnLeadSec) } }
    var playSounds: Bool { didSet { save(Key.playSounds, playSounds) } }
    var showCountdownInMenuBar: Bool { didSet { save(Key.showCountdownInMenuBar, showCountdownInMenuBar) } }

    // Smart Pause — each signal individually toggleable at runtime
    var pauseOnMic: Bool { didSet { save(Key.pauseOnMic, pauseOnMic) } }
    var pauseOnCamera: Bool { didSet { save(Key.pauseOnCamera, pauseOnCamera) } }
    var pauseOnScreenCapture: Bool { didSet { save(Key.pauseOnScreenCapture, pauseOnScreenCapture) } }
    var pauseOnMedia: Bool { didSet { save(Key.pauseOnMedia, pauseOnMedia) } }
    var pauseOnFullscreen: Bool { didSet { save(Key.pauseOnFullscreen, pauseOnFullscreen) } }
    var pauseOnDeepFocusApps: Bool { didSet { save(Key.pauseOnDeepFocusApps, pauseOnDeepFocusApps) } }
    /// After a pause condition clears, hold breaks this much longer.
    var contextLingerSec: Int { didSet { save(Key.contextLingerSec, contextLingerSec) } }

    // Idle / natural breaks
    var idleEnabled: Bool { didSet { save(Key.idleEnabled, idleEnabled) } }
    var idleThresholdSec: Int { didSet { save(Key.idleThresholdSec, idleThresholdSec) } }

    // Office hours
    var officeHoursEnabled: Bool { didSet { save(Key.officeHoursEnabled, officeHoursEnabled) } }
    var officeStartMin: Int { didSet { save(Key.officeStartMin, officeStartMin) } }
    var officeEndMin: Int { didSet { save(Key.officeEndMin, officeEndMin) } }
    var officeDays: Set<Int> { didSet { save(Key.officeDays, Array(officeDays)) } }

    // Deep-focus apps (bundle IDs that hold breaks while frontmost)
    var deepFocusApps: Set<String> { didSet { save(Key.deepFocusApps, Array(deepFocusApps)) } }

    private var postPending = false

    /// Writes and posts one coalesced change notification per runloop turn.
    /// SwiftUI bindings write unconditionally and Steppers auto-repeat at
    /// ~10 Hz; without the guard+coalesce every tick sweeps all detectors
    /// and re-persists the engine snapshot.
    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        guard !postPending else { return }
        postPending = true
        DispatchQueue.main.async { [weak self] in
            self?.postPending = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    // Derived intervals as TimeInterval
    var shortInterval: TimeInterval { TimeInterval(shortIntervalMin * 60) }
    var shortDuration: TimeInterval { TimeInterval(shortDurationSec) }
    var longInterval: TimeInterval { TimeInterval(longIntervalMin * 60) }
    var longDuration: TimeInterval { TimeInterval(longDurationSec) }
    var warnLead: TimeInterval { TimeInterval(warnLeadSec) }
}
