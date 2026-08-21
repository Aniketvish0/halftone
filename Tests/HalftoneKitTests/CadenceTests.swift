import Testing
import Foundation
@testable import HalftoneKit

/// Long-break cadence: time-based, so any short/long ratio works.
/// Pure tests against the engine's real static rule; no shared state.
@MainActor
struct CadenceTests {

    /// Drives the engine's real cadence rule over a simulated schedule.
    func simulate(shortMin: Double, longMin: Double, cycles: Int) -> [BreakKind] {
        var lastLong = Date()
        var now = Date()
        var kinds: [BreakKind] = []
        for _ in 0..<cycles {
            let due = now.addingTimeInterval(shortMin * 60)
            let kind = BreakEngine.kind(dueAt: due, lastLongBreakAt: lastLong,
                                        longInterval: longMin * 60)
            kinds.append(kind)
            if kind == .long { lastLong = due }
            now = due
        }
        return kinds
    }

    @Test func defaultTwentySixtyGivesEveryThirdLong() {
        let kinds = simulate(shortMin: 20, longMin: 60, cycles: 6)
        #expect(kinds == [.short, .short, .long, .short, .short, .long])
    }

    @Test func closeRatioAlternates() {
        // The old integer-division bug made EVERY break long here.
        let kinds = simulate(shortMin: 20, longMin: 30, cycles: 4)
        #expect(kinds == [.short, .long, .short, .long])
        #expect(kinds.first == .short, "first break at 20m must be short")
    }

    @Test func longEqualShortMakesEveryBreakLong() {
        let kinds = simulate(shortMin: 30, longMin: 30, cycles: 3)
        #expect(kinds.allSatisfy { $0 == .long })
    }

    @Test func hugeLongIntervalStaysShort() {
        let kinds = simulate(shortMin: 20, longMin: 240, cycles: 11)
        #expect(kinds.prefix(11).filter { $0 == .long }.count == 0,
                "220min elapsed < 240min: all short so far")
    }

}
