import Foundation

/// Pure helper: is now within office hours, and when is the next boundary?
@MainActor
enum OfficeHours {
    struct Config {
        var enabled: Bool
        var days: Set<Int>      // Calendar weekday numbers (1 = Sunday)
        var startMin: Int
        var endMin: Int

        @MainActor
        static var fromPreferences: Config {
            let p = Preferences.shared
            return Config(enabled: p.officeHoursEnabled, days: p.officeDays,
                          startMin: p.officeStartMin, endMin: p.officeEndMin)
        }
    }

    static func isActive(now: Date = Date(), config: Config? = nil) -> Bool {
        let config = config ?? .fromPreferences
        guard config.enabled else { return true } // disabled = always active
        let cal = Calendar.current
        guard config.days.contains(cal.component(.weekday, from: now)) else { return false }
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return minutes >= config.startMin && minutes < config.endMin
    }

    /// Next moment the active/inactive state could flip (for timer arming).
    static func nextBoundary(now: Date = Date(), config: Config? = nil) -> Date? {
        let config = config ?? .fromPreferences
        guard config.enabled else { return nil }
        let cal = Calendar.current
        for dayOffset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))
            else { continue }
            guard config.days.contains(cal.component(.weekday, from: day)) else { continue }
            for mins in [config.startMin, config.endMin] {
                if let d = cal.date(byAdding: .minute, value: mins, to: day), d > now {
                    return d
                }
            }
        }
        return nil
    }
}
