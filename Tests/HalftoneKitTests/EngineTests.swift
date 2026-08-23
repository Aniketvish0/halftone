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

// MARK: - Toggle latency contract (500ms budget)

@MainActor
extension EngineTests {

    /// The full user path: detector active + enabled -> hold; user flips the
    /// toggle OFF in Settings -> hold releases. Measures wall-clock latency
    /// end to end through the real preference-notification machinery.
    @Test func toggleOffReleasesHoldWithin500ms() async {
        let engine = makeEngine()
        let fake = engine.context._testInstallDetector(
            flag: .mediaPlaying, enabled: \.pauseOnMedia)

        prefs.pauseOnMedia = true
        await drainMainQueue()
        fake.simulate(detected: true)
        #expect(engine.context.shouldHold, "active+enabled detector must hold")
        #expect(engine.context.activeFlags == [.mediaPlaying])

        let flipAt = Date()
        prefs.pauseOnMedia = false
        // Wait until released, sampling the runloop; fail past the budget.
        while engine.context.shouldHold, Date().timeIntervalSince(flipAt) < 1.0 {
            await drainMainQueue()
        }
        let latency = Date().timeIntervalSince(flipAt)
        print("MEASURED toggle-off release latency: \(Int(latency * 1000))ms")
        #expect(!engine.context.shouldHold, "toggle off must release the hold")
        #expect(latency < 0.5, "release took \(Int(latency * 1000))ms; budget is 500ms")
    }

    /// Toggle ON while the activity is already happening must hold promptly.
    @Test func toggleOnDetectsWithin500ms() async {
        let engine = makeEngine()
        let fake = engine.context._testInstallDetector(
            flag: .mediaPlaying, enabled: \.pauseOnMedia)

        prefs.pauseOnMedia = false
        await drainMainQueue()
        fake.simulate(detected: true) // stopped detector: ignored
        #expect(!engine.context.shouldHold, "disabled detector must not hold")

        let flipAt = Date()
        prefs.pauseOnMedia = true
        while !engine.context.shouldHold, Date().timeIntervalSince(flipAt) < 1.0 {
            await drainMainQueue()
        }
        let latency = Date().timeIntervalSince(flipAt)
        print("MEASURED toggle-on hold latency: \(Int(latency * 1000))ms")
        #expect(engine.context.shouldHold, "toggle on during activity must hold")
        #expect(latency < 0.5, "hold took \(Int(latency * 1000))ms; budget is 500ms")
    }

    /// Activity ending NATURALLY must keep holding through the linger window
    /// (toggle-off releases instantly; a call's silence must not).
    @Test func naturalEndLingersButToggleOffDoesNot() async {
        let engine = makeEngine()
        let fake = engine.context._testInstallDetector(
            flag: .micInUse, enabled: \.pauseOnMic)
        prefs.pauseOnMic = true
        prefs.contextLingerSec = 60
        await drainMainQueue()

        fake.simulate(detected: true)
        #expect(engine.context.shouldHold)

        // Natural end: detector reports gone, hold must persist (linger).
        fake.simulate(detected: false)
        #expect(engine.context.shouldHold, "natural end must linger, not drop instantly")

        // Toggle off mid-linger: must release immediately.
        prefs.pauseOnMic = false
        await drainMainQueue()
        #expect(!engine.context.shouldHold, "toggle off mid-linger must release now")
    }
}

// MARK: - Idle suppression is independent of the hold toggle

@MainActor
extension EngineTests {

    /// Field bug: with 'Video playing' hold-toggle OFF, watching YouTube
    /// counted as being away (moon icon while actively watching). The
    /// suppression signal must track raw detection, not the hold toggle.
    @Test func mediaSuppressesIdleEvenWhenHoldToggleIsOff() async {
        prefs.pauseOnMedia = false
        prefs.idleEnabled = true
        await drainMainQueue()
        let engine = makeEngine()
        let fake = engine.context._testInstallDetector(
            flag: .mediaPlaying, enabled: \.pauseOnMedia)

        #expect(fake.running,
                "media-flag detector must run for idle suppression when idle is on")

        fake.simulate(detected: true)
        #expect(engine.context.isMediaPlaying,
                "raw detection must surface with the hold toggle off")
        #expect(!engine.context.activeFlags.contains(.mediaPlaying),
                "but it must NOT hold breaks (toggle is off)")
        #expect(!engine.context.shouldHold)
    }

    /// Both consumers off: the detector must actually stop.
    @Test func mediaDetectorStopsWhenNoConsumerNeedsIt() async {
        prefs.pauseOnMedia = false
        prefs.idleEnabled = false
        await drainMainQueue()
        let engine = makeEngine()
        let fake = engine.context._testInstallDetector(
            flag: .mediaPlaying, enabled: \.pauseOnMedia)
        #expect(!fake.running,
                "no hold toggle, no idle: detector must not run")
        #expect(!engine.context.isMediaPlaying)
    }
}

// MARK: - Phase 3: ambient glow window + reminder suppression

@MainActor
extension EngineTests {

    /// Glow lead must not move the due date (it only adds a wake milestone).
    @Test func glowLeadDoesNotMoveTheDueDate() async {
        prefs.ambientGlowEnabled = true
        prefs.ambientGlowLeadSec = 120
        prefs.warnLeadSec = 30
        await drainMainQueue()
        let engine = makeEngine()
        // Indirect but deterministic check: the state machine still reports
        // .working with the full interval; the glow lead only moves the
        // internal wake point. Verify the due date is unaffected by glow.
        let due = workingDue(engine)
        #expect(due != nil)
        if let due { #expect(abs(due.timeIntervalSinceNow - 20 * 60) < 2) }
        prefs.ambientGlowEnabled = false
        await drainMainQueue()
    }

    /// Reminder suppression: asserts the engine's OWN gate (the one the app
    /// wires), not a copy of its logic.
    @Test func reminderSuppressionGate() {
        let engine = makeEngine()
        #expect(engine.allowsMicroReminders, "plain working: reminders allowed")
        engine.context._testSetHold(true)
        #expect(!engine.allowsMicroReminders, "hold: reminders blocked")
        engine.context._testSetHold(false)
        engine.startBreakNow()
        #expect(!engine.allowsMicroReminders, "in break: reminders blocked")
        engine.skipBreak()
        engine.pause()
        #expect(!engine.allowsMicroReminders, "paused: reminders blocked")
        engine.resume()
        #expect(engine.allowsMicroReminders, "resumed working: reminders allowed again")
    }

    /// Strictness preference round-trips through its raw string.
    @Test func strictnessPersistsAndParses() {
        let original = prefs.strictness
        for level in Strictness.allCases {
            prefs.strictness = level
            #expect(Strictness(rawValue: Defaults.store.string(forKey: "strictness") ?? "") == level)
        }
        prefs.strictness = original
    }
}

// MARK: - Ambient glow controller contracts

@MainActor
extension EngineTests {

    /// evaluate() may run several times inside the glow window; the ramp
    /// must not restart for the same target break.
    @Test func glowShowIsIdempotentPerTarget() {
        let glow = AmbientGlowController()
        let target = Date().addingTimeInterval(90)
        glow.show(breakAt: target)
        let first = glow._testPanelIDs
        glow.show(breakAt: target)                    // same target: no rebuild
        #expect(glow._testPanelIDs == first, "same-target show must not rebuild panels")
        glow.show(breakAt: target.addingTimeInterval(300)) // new target: rebuild
        #expect(glow._testPanelIDs != first, "new target must rebuild")
        glow.hide()
        #expect(glow._testPanelIDs.isEmpty)
    }
}

// MARK: - Toggle x detection matrix

@MainActor
extension EngineTests {

    /// Every (toggle, detection) permutation across two flags: the flag set,
    /// hold state, and menu icon must all agree. This is the class of bug
    /// from the field: one signal toggled off while another stays detected.
    @Test func toggleDetectionMatrixKeepsFlagsHoldAndIconConsistent() async {
        let engine = makeEngine()
        let media = engine.context._testInstallDetector(flag: .mediaPlaying, enabled: \.pauseOnMedia)
        let fullscreen = engine.context._testInstallDetector(flag: .fullscreenApp, enabled: \.pauseOnFullscreen)

        for mediaOn in [false, true] {
            for fsOn in [false, true] {
                for mediaDetected in [false, true] {
                    for fsDetected in [false, true] {
                        prefs.pauseOnMedia = mediaOn
                        prefs.pauseOnFullscreen = fsOn
                        await drainMainQueue()
                        media.simulate(detected: mediaDetected)
                        fullscreen.simulate(detected: fsDetected)

                        var expected: Set<ContextFlag> = []
                        if mediaOn && mediaDetected { expected.insert(.mediaPlaying) }
                        if fsOn && fsDetected { expected.insert(.fullscreenApp) }

                        let label = "media(on:\(mediaOn) det:\(mediaDetected)) fs(on:\(fsOn) det:\(fsDetected))"
                        #expect(engine.context.activeFlags == expected, "flags wrong for \(label)")

                        if !expected.isEmpty {
                            #expect(engine.context.shouldHold, "must hold for \(label)")
                            // The icon must reflect the top-priority ACTIVE reason.
                            let display = MenuBarDisplay.compute(
                                state: engine.state, shouldHold: true,
                                holdReasons: engine.context.holdReasons,
                                showCountdown: true, now: Date())
                            let top = expected.min(by: { $0.priority < $1.priority })!
                            #expect(display.symbol == top.symbolName, "icon wrong for \(label)")
                        }

                        // Clear detections and release the hold instantly so
                        // the next permutation starts clean (toggle-off path).
                        media.simulate(detected: false)
                        fullscreen.simulate(detected: false)
                        prefs.pauseOnMedia = false
                        prefs.pauseOnFullscreen = false
                        await drainMainQueue()
                    }
                }
            }
        }
    }
}

// MARK: - Micro-reminder delivery lifecycle

@MainActor
extension EngineTests {

    @Test func reminderFiresWhileWorkingAndDefersWhileSuppressed() async {
        prefs.blinkEnabled = true
        await drainMainQueue()
        let engine = makeEngine()
        let reminders = MicroReminders()
        var shown: [MicroReminders.Kind] = []
        reminders._testPresent = { shown.append($0) }
        reminders.isSuppressed = { [weak engine] in
            !(engine?.allowsMicroReminders ?? false)
        }

        // Plain working: fires show immediately.
        reminders.fire(.blink)
        #expect(shown == [.blink], "working: reminder must show")

        // Hold active: fires defer, not drop.
        engine.context._testSetHold(true)
        reminders.setActive(engine.allowsMicroReminders)
        reminders.fire(.blink)
        reminders.fire(.posture)
        reminders.fire(.blink) // duplicate while suppressed: dedup to one
        #expect(shown == [.blink], "suppressed: nothing new shows yet")

        // Hold clears: deferred reminders flush (staggered via asyncAfter).
        engine.context._testSetHold(false)
        reminders.setActive(engine.allowsMicroReminders)
        // First flush lands at +2s; drain the main queue past it.
        try? await Task.sleep(for: .seconds(2.3))
        await drainMainQueue()
        #expect(shown.count >= 2, "deferred blink must flush after release (got \(shown))")
        #expect(shown.filter { $0 == .blink }.count == 2, "blink deferred once, not twice")

        prefs.blinkEnabled = false
        await drainMainQueue()
    }
}

// MARK: - Idle during engagement (the mid-call restart)

@MainActor
extension EngineTests {

    /// THE FIELD BUG: hands-still on a call crossed the idle threshold; when
    /// the "return" fired, away >= shortDuration credited a break and started
    /// a FRESH cycle, restarting a countdown that had been at 2 minutes left.
    /// Cancellation must restore the pending countdown exactly.
    @Test func idleCancellationRestoresPendingCountdownExactly() {
        let engine = makeEngine()
        let dueBefore = workingDue(engine)!

        // Engine goes idle carrying the pending countdown (hands still).
        engine._testEnterIdle(pending: .init(dueAt: dueBefore, kind: .short))

        // Engagement appears with no input: cancellation, not return.
        engine._testIdleCancelled()

        let dueAfter = workingDue(engine)
        #expect(dueAfter != nil, "cancellation must restore working")
        if let dueAfter {
            #expect(abs(dueAfter.timeIntervalSince(dueBefore)) < 1,
                    "due date must be EXACTLY the interrupted one, not a fresh cycle")
        }
    }

    /// A real return (fresh input) after >= shortDuration away still credits
    /// the break: cancellation must not have broken the genuine path.
    @Test func realReturnStillCreditsBreak() {
        let engine = makeEngine()
        engine._testEnterIdle(pending: nil)
        engine._testReturnedFromIdle(after: 300) // 5 min away, shortDuration 20s
        let due = workingDue(engine)
        #expect(due != nil)
        if let due {
            #expect(abs(due.timeIntervalSinceNow - 20 * 60) < 2,
                    "a genuine long absence starts a fresh cycle")
        }
    }

    /// isEngaged covers all four engagement signals raw, and ignores toggles.
    @Test func engagementCoversAllFourSignalsRegardlessOfToggles() async {
        prefs.pauseOnMic = false
        prefs.pauseOnCamera = false
        prefs.pauseOnScreenCapture = false
        prefs.pauseOnMedia = false
        prefs.idleEnabled = true
        await drainMainQueue()
        let engine = makeEngine()

        // Replace ALL engagement detectors up front: leaving any real one
        // in the table lets actual machine state (a live call, playing
        // audio) leak into assertions — the exact leak the detection matrix
        // test caught last round.
        let pairs: [(ContextFlag, KeyPath<Preferences, Bool>)] = [
            (.micInUse, \.pauseOnMic),
            (.cameraInUse, \.pauseOnCamera),
            (.screenCaptured, \.pauseOnScreenCapture),
            (.mediaPlaying, \.pauseOnMedia),
        ]
        let fakes = pairs.map { engine.context._testInstallDetector(flag: $0.0, enabled: $0.1) }

        for (i, (flag, _)) in pairs.enumerated() {
            let fake = fakes[i]
            #expect(fake.running, "\(flag): engagement detector must run for idle even with toggle off")
            fake.simulate(detected: true)
            #expect(engine.context.isEngaged, "\(flag): raw detection must register as engagement")
            #expect(!engine.context.shouldHold, "\(flag): toggle off, must NOT hold")
            fake.simulate(detected: false)
            #expect(!engine.context.isEngaged, "\(flag): must clear")
        }
        prefs.idleEnabled = false
        await drainMainQueue()
    }
}
