import Foundation

/// Pure helper: is now within office hours, and when is the next boundary?
@MainActor
enum OfficeHours {
    static func isActive(now: Date = Date()) -> Bool {
        let prefs = Preferences.shared
        guard prefs.officeHoursEnabled else { return true } // disabled = always active
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        guard prefs.officeDays.contains(weekday) else { return false }
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return minutes >= prefs.officeStartMin && minutes < prefs.officeEndMin
    }

    /// Next moment the active/inactive state could flip (for timer arming).
    static func nextBoundary(now: Date = Date()) -> Date? {
        let prefs = Preferences.shared
        guard prefs.officeHoursEnabled else { return nil }
        let cal = Calendar.current
        // Check today's start/end, then tomorrow's start, up to 8 days out.
        for dayOffset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))
            else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard prefs.officeDays.contains(weekday) else { continue }
            for mins in [prefs.officeStartMin, prefs.officeEndMin] {
                if let d = cal.date(byAdding: .minute, value: mins, to: day), d > now {
                    return d
                }
            }
        }
        return nil
    }
}
