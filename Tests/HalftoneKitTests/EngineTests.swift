import Testing
import Foundation
@testable import HalftoneKit

/// Engine tests drive the real state machine with real (short) time values.
/// Serialized: they share Preferences.shared and the defaults store.
@MainActor
@Suite(.serialized)
struct EngineTests {

    var prefs: Preferences { Preferences.shared }

    init() async {
        Defaults.store.removeObject(forKey: "engineSnapshot")
        prefs.shortIntervalMin = 20
        prefs.longIntervalMin = 60
        prefs.shortDurationSec = 20
        prefs.longDurationSec = 300
        prefs.warnLeadSec = 30
        prefs.playSounds = false
        prefs.idleEnabled = false
        prefs.officeHoursEnabled = false
        await drainMainQueue()
    }

    /// Preference posts coalesce onto the next runloop turn.
    func drainMainQueue() async {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    func makeEngine() -> BreakEngine {
        let engine = BreakEngine()
        engine.start()
        return engine
    }

    func workingDue(_ engine: BreakEngine) -> Date? {
        if case .working(let due, _) = engine.state { return due }
        return nil
    }

    // MARK: State machine basics

    @Test func startEntersWorkingWithFullInterval() {
        let engine = makeEngine()
        let due = try! #require(workingDue(engine))
        #expect(abs(due.timeIntervalSinceNow - 20 * 60) < 2)
    }

    @Test func startBreakNowEntersBreakAndSkipReturns() {
        let engine = makeEngine()
        engine.startBreakNow()
        guard case .inBreak(_, let endsAt) = engine.state else {
            Issue.record("not inBreak"); return
        }
        #expect(abs(endsAt.timeIntervalSinceNow - 20) < 2)
        engine.skipBreak()
        #expect(workingDue(engine) != nil, "skip should return to working")
    }

    @Test func pauseResumeKeepsRemaining() {
        let engine = makeEngine()
        let before = workingDue(engine)!
        engine.pause()
        guard case .pausedByUser(until: nil) = engine.state else {
            Issue.record("not paused"); return
        }
        engine.resume()
        let after = workingDue(engine)!
        #expect(abs(after.timeIntervalSince(before)) < 3)
    }

    @Test func timedPauseStoresUntil() {
        let engine = makeEngine()
        engine.pause(for: 3600)
        guard case .pausedByUser(let until) = engine.state, let until else {
            Issue.record("not timed-paused"); return
        }
        #expect(abs(until.timeIntervalSinceNow - 3600) < 2)
    }

    @Test func snoozePushesBreakOut() {
        let engine = makeEngine()
        engine.startBreakNow()
        engine.snooze(15 * 60)
        let due = workingDue(engine)
        #expect(due != nil)
        if let due { #expect(abs(due.timeIntervalSinceNow - 15 * 60) < 2) }
    }

    // MARK: Preferences interaction

    @Test func unrelatedPrefChangeKeepsDueDate() async {
        let engine = makeEngine()
        let before = workingDue(engine)!
        prefs.playSounds.toggle()
        await drainMainQueue()
        prefs.playSounds.toggle()
        await drainMainQueue()
        #expect(abs(workingDue(engine)!.timeIntervalSince(before)) < 1)
    }

    @Test func intervalChangeRederivesFromCycleStart() async {
        let engine = makeEngine()
        let before = workingDue(engine)!
        prefs.shortIntervalMin = 25
        await drainMainQueue()
        let after = workingDue(engine)!
        #expect(abs(after.timeIntervalSince(before) - 5 * 60) < 2,
                "20→25 min must move due by +5min, not restart")
    }

    // MARK: Context hold interactions

    @Test func forceBreakBypassesHold() {
        let engine = makeEngine()
        engine.context._testSetHold(true)
        engine.startBreakNow()
        var inBreak = false
        if case .inBreak = engine.state { inBreak = true }
        #expect(inBreak, "explicit Take Break Now must bypass hold")
        engine.skipBreak()
        engine.context._testSetHold(false)
    }

    @Test func holdDuringBreakEndsBreak() {
        let engine = makeEngine()
        engine.startBreakNow()
        engine.context._testSetHold(true)
        #expect(workingDue(engine) != nil, "hold mid-break must end the break")
        engine.context._testSetHold(false)
    }

    @Test func pauseWhileHeldResumesToShortCountdown() {
        let engine = makeEngine()
        engine.context._testSetHold(true)
        engine.pause()
        engine.context._testSetHold(false)
        engine.resume()
        #expect(workingDue(engine) != nil)
    }

    // MARK: Session resume

    @Test func snapshotRoundTrip() {
        let engine = makeEngine()
        let due = workingDue(engine)!
        let engine2 = BreakEngine()
        engine2.start()
        let restored = workingDue(engine2)
        #expect(restored != nil, "fresh future snapshot must restore")
        if let restored { #expect(abs(restored.timeIntervalSince(due)) < 1) }
    }

    @Test func staleSnapshotIsIgnored() {
        struct Snap: Codable {
            var savedAt: Date; var lastLongBreakAt: Date?
            var workingDueAt: Date?; var workingKind: BreakKind?
        }
        let stale = Snap(savedAt: Date(timeIntervalSinceNow: -7200),
                         lastLongBreakAt: nil,
                         workingDueAt: Date(timeIntervalSinceNow: -3600),
                         workingKind: .short)
        Defaults.store.set(try! JSONEncoder().encode(stale), forKey: "engineSnapshot")
        let engine = makeEngine()
        let due = workingDue(engine)
        #expect(due != nil)
        if let due {
            #expect(abs(due.timeIntervalSinceNow - 20 * 60) < 2,
                    "stale snapshot must yield a fresh cycle")
        }
    }
}
