import Foundation
import Observation

/// All user preferences. Single source of truth backed by UserDefaults.
/// Views bind to this; the engine re-reads on change notification.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()
    static let changed = Notification.Name("HalftonePreferencesChanged")

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            Key.shortIntervalMin: 20,
            Key.shortDurationSec: 20,
            Key.longIntervalMin: 60,
            Key.longDurationSec: 300,
            Key.warnLeadSec: 30,
            Key.playSounds: true,
            Key.showCountdownInMenuBar: true,
        ])
        shortIntervalMin = d.integer(forKey: Key.shortIntervalMin)
        shortDurationSec = d.integer(forKey: Key.shortDurationSec)
        longIntervalMin = d.integer(forKey: Key.longIntervalMin)
        longDurationSec = d.integer(forKey: Key.longDurationSec)
        warnLeadSec = d.integer(forKey: Key.warnLeadSec)
        playSounds = d.bool(forKey: Key.playSounds)
        showCountdownInMenuBar = d.bool(forKey: Key.showCountdownInMenuBar)
    }

    private enum Key {
        static let shortIntervalMin = "shortIntervalMin"
        static let shortDurationSec = "shortDurationSec"
        static let longIntervalMin = "longIntervalMin"
        static let longDurationSec = "longDurationSec"
        static let warnLeadSec = "warnLeadSec"
        static let playSounds = "playSounds"
        static let showCountdownInMenuBar = "showCountdownInMenuBar"
    }

    var shortIntervalMin: Int = 20 { didSet { save(Key.shortIntervalMin, shortIntervalMin) } }
    var shortDurationSec: Int = 20 { didSet { save(Key.shortDurationSec, shortDurationSec) } }
    var longIntervalMin: Int = 60 { didSet { save(Key.longIntervalMin, longIntervalMin) } }
    var longDurationSec: Int = 300 { didSet { save(Key.longDurationSec, longDurationSec) } }
    var warnLeadSec: Int = 30 { didSet { save(Key.warnLeadSec, warnLeadSec) } }
    var playSounds: Bool = true { didSet { save(Key.playSounds, playSounds) } }
    var showCountdownInMenuBar: Bool = true { didSet { save(Key.showCountdownInMenuBar, showCountdownInMenuBar) } }

    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // Derived intervals as TimeInterval
    var shortInterval: TimeInterval { TimeInterval(shortIntervalMin * 60) }
    var shortDuration: TimeInterval { TimeInterval(shortDurationSec) }
    var longInterval: TimeInterval { TimeInterval(longIntervalMin * 60) }
    var longDuration: TimeInterval { TimeInterval(longDurationSec) }
    var warnLead: TimeInterval { TimeInterval(warnLeadSec) }
}
