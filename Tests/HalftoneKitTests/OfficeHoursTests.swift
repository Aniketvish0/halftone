import Testing
import Foundation
@testable import HalftoneKit

/// Pure-config tests: no shared Preferences, safe under parallel suites.
@MainActor
struct OfficeHoursTests {

    let nineToSixWeekdays = OfficeHours.Config(
        enabled: true, days: [2, 3, 4, 5, 6], startMin: 9 * 60, endMin: 18 * 60)

    func date(weekday targetWeekday: Int, hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        var probe = cal.startOfDay(for: Date())
        for _ in 0..<8 {
            if cal.component(.weekday, from: probe) == targetWeekday { break }
            probe = cal.date(byAdding: .day, value: 1, to: probe)!
        }
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: probe)!
    }

    @Test func boundaries() {
        let c = nineToSixWeekdays
        #expect(OfficeHours.isActive(now: date(weekday: 5, hour: 9, minute: 0), config: c))
        #expect(!OfficeHours.isActive(now: date(weekday: 5, hour: 8, minute: 59), config: c))
        #expect(OfficeHours.isActive(now: date(weekday: 5, hour: 17, minute: 59), config: c))
        #expect(!OfficeHours.isActive(now: date(weekday: 5, hour: 18, minute: 0), config: c))
        #expect(!OfficeHours.isActive(now: date(weekday: 7, hour: 12, minute: 0), config: c))
        #expect(!OfficeHours.isActive(now: date(weekday: 1, hour: 12, minute: 0), config: c))
    }

    @Test func disabledMeansAlwaysActive() {
        let c = OfficeHours.Config(enabled: false, days: [], startMin: 0, endMin: 0)
        #expect(OfficeHours.isActive(now: date(weekday: 7, hour: 3, minute: 0), config: c))
    }

    @Test func nextBoundaryIsAlwaysAheadAndFlips() {
        let c = nineToSixWeekdays
        // From Thursday noon, the next boundary is Thursday 18:00.
        let thuNoon = date(weekday: 5, hour: 12, minute: 0)
        let boundary = OfficeHours.nextBoundary(now: thuNoon, config: c)
        #expect(boundary != nil)
        if let boundary {
            #expect(boundary > thuNoon)
            let cal = Calendar.current
            #expect(cal.component(.hour, from: boundary) == 18)
        }
    }

    @Test func fromSaturdayNextBoundaryIsMondayStart() {
        let c = nineToSixWeekdays
        let satNoon = date(weekday: 7, hour: 12, minute: 0)
        let boundary = OfficeHours.nextBoundary(now: satNoon, config: c)
        #expect(boundary != nil)
        if let boundary {
            let cal = Calendar.current
            #expect(cal.component(.weekday, from: boundary) == 2, "Monday")
            #expect(cal.component(.hour, from: boundary) == 9)
        }
    }

    @Test func disabledHasNoBoundary() {
        let c = OfficeHours.Config(enabled: false, days: [], startMin: 0, endMin: 0)
        #expect(OfficeHours.nextBoundary(config: c) == nil)
    }
}
