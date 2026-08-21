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
        prefs.pauseOnMic = false
        prefs.pauseOnCamera = false
        prefs.pauseOnScreenCapture = false
        prefs.pauseOnMedia = false
        prefs.pauseOnFullscreen = false
        prefs.pauseOnDeepFocusApps = false
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
        engine._testEnterHeld()
        var wasHeld = false
        if case .heldByContext = engine.state { wasHeld = true }
        #expect(wasHeld)
        engine.pause()
        engine.context._testSetHold(false)
        engine.resume()
        // Pausing from held records a 30s floor, not the full interval.
        let due = workingDue(engine)
        #expect(due != nil)
        if let due { #expect(due.timeIntervalSinceNow < 60, "held pause resumes short, not full cycle") }
    }

    @Test func holdReleaseFromHeldEntersGraceWarning() {
        let engine = makeEngine()
        engine.context._testSetHold(true)
        engine._testEnterHeld()
        engine.context._testSetHold(false)
        // contextChanged on release routes held -> warnSoon (15s grace warning).
        var warned = false
        if case .warning(let at, _) = engine.state {
            warned = true
            #expect(abs(at.timeIntervalSinceNow - 15) < 2)
        }
        #expect(warned, "hold release must enter the 15s grace warning")
    }

    // MARK: Cadence (engine-integrated)

    @Test func engineFirstBreakKindMatchesRule() {
        let engine = makeEngine()
        guard case .working(_, let kind) = engine.state else {
            Issue.record("not working"); return
        }
        #expect(kind == .short, "fresh start: first break 20m out, long due at 60m")
    }

    // MARK: Context engine

    @Test func holdSetAndReleaseViaSeam() {
        let engine = makeEngine()
        var changes = 0
        engine.context.onChange = { changes += 1 }
        engine.context._testSetHold(true)
        #expect(engine.context.shouldHold)
        #expect(engine.context.holdReasons == [.micInUse])
        engine.context._testSetHold(false)
        #expect(!engine.context.shouldHold)
        #expect(changes >= 2)
    }

    @Test func disabledDetectorsContributeNoFlags() {
        let engine = makeEngine()
        #expect(engine.context.activeFlags.isEmpty)
    }

    // MARK: Preferences

    @Test func changesCoalesceToOnePostPerRunloopTurn() async {
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let original = prefs.warnLeadSec
        for v in [10, 15, 20, 25, 30] { prefs.warnLeadSec = v }
        await drainMainQueue()
        #expect(posts == 1, "5 writes in one turn must post once (got \(posts))")
        prefs.warnLeadSec = original
        await drainMainQueue()
    }

    @Test func valuesPersistToStore() {
        let original = prefs.shortDurationSec
        prefs.shortDurationSec = 45
        #expect(Defaults.store.integer(forKey: "shortDurationSec") == 45)
        prefs.shortDurationSec = original
    }

    @Test func officeDaysRoundTripsAsSet() {
        let original = prefs.officeDays
        prefs.officeDays = [1, 7]
        let stored = Set((Defaults.store.array(forKey: "officeDays") as? [Int]) ?? [])
        #expect(stored == [1, 7])
        prefs.officeDays = original
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
