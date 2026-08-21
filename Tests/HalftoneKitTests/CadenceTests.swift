import Testing
import Foundation
@testable import HalftoneKit

/// Long-break cadence: time-based, so any short/long ratio works.
@MainActor
@Suite(.serialized)
struct CadenceTests {

    init() async {
        Defaults.store.removeObject(forKey: "engineSnapshot")
        let prefs = Preferences.shared
        prefs.playSounds = false
        prefs.idleEnabled = false
        prefs.officeHoursEnabled = false
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    /// Replicates kindForBreak's rule over a simulated schedule.
    func simulate(shortMin: Double, longMin: Double, cycles: Int) -> [BreakKind] {
        var lastLong = Date()
        var now = Date()
        var kinds: [BreakKind] = []
        for _ in 0..<cycles {
            let due = now.addingTimeInterval(shortMin * 60)
            let kind: BreakKind = due.timeIntervalSince(lastLong) >= longMin * 60 ? .long : .short
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

    /// The engine itself must agree with the simulation on the first kind.
    @Test func engineFirstBreakKindMatchesRule() async {
        let prefs = Preferences.shared
        prefs.shortIntervalMin = 20
        prefs.longIntervalMin = 60
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        let engine = BreakEngine()
        engine.start()
        guard case .working(_, let kind) = engine.state else {
            Issue.record("not working"); return
        }
        #expect(kind == .short, "fresh start: first break 20m out, long due at 60m")
    }
}
