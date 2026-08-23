import Foundation
import AppKit
import Observation

enum BreakKind: String, Codable {
    case short, long
}

/// The heart of Halftone: a Date-anchored state machine with exactly ONE armed
/// timer at any moment (armed at the next endpoint, generous leeway).
/// All countdowns shown in UI are system-rendered from the Dates stored here —
/// the app itself never ticks.
@Observable
@MainActor
final class BreakEngine {

    enum State: Equatable {
        case working(nextBreakAt: Date, kind: BreakKind)
        case warning(breakAt: Date, kind: BreakKind)
        case inBreak(kind: BreakKind, endsAt: Date)
        case pausedByUser(until: Date?) // nil = indefinitely
        /// Smart Pause: a break came due while a hold condition was active.
        /// `overdueSince` preserves when it should have fired.
        case heldByContext(kind: BreakKind, overdueSince: Date)
        /// User stepped away. `pending` carries the interrupted countdown so a
        /// short absence can restore it instead of restarting the cycle.
        case idle(since: Date, pending: PendingBreak?)
        /// Outside configured office hours; scheduling suspended.
        case offHours
    }

    struct PendingBreak: Equatable {
        var dueAt: Date
        var kind: BreakKind
    }

    /// Delay between a break becoming possible again (hold cleared, interval
    /// already exceeded, came due while away) and the warning firing.
    private static let overdueGrace: TimeInterval = 15

    private(set) var state: State = .pausedByUser(until: nil)

    /// When the current work cycle began. Lets a preference change re-derive
    /// the due date without discarding time already worked.
    private var cycleStartedAt = Date()

    /// Long-break cadence is time-based: a break whose due date lands at least
    /// `longInterval` after the last completed long break becomes long.
    private var lastLongBreakAt = Date()

    /// Time left on the countdown when the user paused, so resume continues
    /// where they stopped instead of restarting the full interval.
    private var pausedRemaining: (kind: BreakKind, remaining: TimeInterval)?

    private let wakeRecovery = RepeatingPoller()

    private let prefs = Preferences.shared
    private var timer: DispatchSourceTimer?

    var overlayController: OverlayController?
    var warningPill: WarningPillController?
    var ambientGlow: AmbientGlowController?
    let context = ContextEngine()
    private let idleMonitor = IdleMonitor()

    init() {
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWoke() }
        }

        context.onChange = { [weak self] in self?.contextChanged() }

        idleMonitor.isSuppressed = { [weak self] in
            // Watching a video with hands off the keyboard is not "away":
            // raw detection, deliberately not gated on the pauseOnMedia
            // toggle (that toggle chooses break-holding, not away semantics).
            self?.context.isMediaPlaying ?? false
        }
        idleMonitor.onWentIdle = { [weak self] in self?.enterIdle(since: Date()) }
        idleMonitor.onReturned = { [weak self] away in self?.returnedFromIdle(after: away) }
        if prefs.idleEnabled { idleMonitor.start() }

        // Sleep/lock also mean "away" — treat like idle without threshold.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWentAway() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWentAway() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemCameBack() }
        }
    }

    // MARK: - Context (Smart Pause) integration

    private func contextChanged() {
        switch state {
        case .warning(let breakAt, let kind):
            if context.shouldHold {
                // Cancel the imminent break; it fires when the hold clears.
                transition(.heldByContext(kind: kind, overdueSince: breakAt))
            }
        case .working(let due, let kind):
            if context.shouldHold {
                // Glow mustn't keep ramping toward a break that will be held.
                ambientGlow?.hide()
                if due.timeIntervalSinceNow < prefs.warnLead {
                    transition(.heldByContext(kind: kind, overdueSince: due))
                }
            }
        case .heldByContext(let kind, _):
            if !context.shouldHold {
                // Hold cleared: let the user breathe, then fire the overdue break.
                warnSoon(kind: kind)
            }
        case .inBreak:
            // A hold beginning mid-break (e.g. answering a call during a
            // break) ends the break — the user clearly needs the screen.
            if context.shouldHold {
                endBreak(completed: false)
            }
        default:
            break
        }
    }

    // MARK: - Idle / away integration

    /// Captures the interrupted countdown (if any) so a short absence can
    /// restore it. Used by both idle detection and lock/sleep.
    private func enterIdle(since: Date) {
        switch state {
        case .working(let due, let kind), .warning(let due, let kind):
            transition(.idle(since: since, pending: PendingBreak(dueAt: due, kind: kind)))
        case .heldByContext(let kind, let overdueSince):
            transition(.idle(since: since, pending: PendingBreak(dueAt: overdueSince, kind: kind)))
        default:
            break
        }
    }

    private func returnedFromIdle(after away: TimeInterval) {
        guard case .idle(_, let pending) = state else { return }
        if away >= prefs.longDuration {
            // Long enough to count as a long break: full cycle reset.
            lastLongBreakAt = Date()
            scheduleNextBreak(from: Date())
        } else if away >= prefs.shortDuration {
            // Counts as a short break: fresh cycle.
            scheduleNextBreak(from: Date())
        } else if let pending {
            // Too short to be a break. The countdown continues where it was;
            // wall clock kept running, so the due date is unchanged.
            if pending.dueAt > Date() {
                enterWorking(due: pending.dueAt, kind: pending.kind)
            } else {
                // Came due while away: warn now, then break.
                warnSoon(kind: pending.kind)
            }
        } else {
            scheduleNextBreak(from: Date())
        }
    }

    private func systemWentAway() {
        switch state {
        case .inBreak, .pausedByUser, .idle:
            break // .idle keeps its original since (enterIdle would no-op anyway)
        default:
            enterIdle(since: Date())
        }
    }

    private func systemCameBack() {
        wakeRecovery.stop()
        // The idle state carries its own timestamp; no separate bookkeeping.
        guard case .idle(let since, _) = state else { return }
        returnedFromIdle(after: Date().timeIntervalSince(since))
    }

    /// Wake without a lock (no password after sleep, auto-login) never posts
    /// screenIsUnlocked — treat wake itself as the return unless the screen is
    /// actually still locked. The unlock notification normally finishes the
    /// job, but its delivery is not guaranteed (observed: engine stuck on the
    /// moon icon for minutes after a next-day wake), so a cheap poll backstops
    /// it: unlocked + fresh input = the user is back, notification or not.
    private func systemWoke() {
        if case .idle = state, !CGSession.flag("CGSSessionScreenIsLocked") {
            systemCameBack()
        } else {
            evaluate()
            startWakeRecoveryIfIdle()
        }
    }

    private func startWakeRecoveryIfIdle() {
        guard case .idle = state else { return }
        wakeRecovery.start(interval: 2, leeway: .seconds(1), firstDelay: 2) { [weak self] in
            guard let self else { return }
            guard case .idle = self.state else {
                self.wakeRecovery.stop()
                return
            }
            if !CGSession.flag("CGSSessionScreenIsLocked"),
               IdleMonitor.secondsSinceLastInput() < 2 {
                self.systemCameBack()
            }
        }
    }

    // MARK: - Office hours

    private func officeHoursChanged() {
        let active = OfficeHours.isActive()
        switch state {
        case .offHours:
            if active { scheduleNextBreak(from: Date()) }
        case .pausedByUser, .inBreak:
            break
        default:
            if !active { transition(.offHours) }
        }
    }

    // MARK: - Public controls

    func start() {
        if !restoreSnapshot() {
            scheduleNextBreak(from: Date())
        }
    }

    func pause(for duration: TimeInterval? = nil) {
        switch state {
        case .working(let due, let kind), .warning(let due, let kind):
            pausedRemaining = (kind, max(30, due.timeIntervalSinceNow))
        case .heldByContext(let kind, _):
            pausedRemaining = (kind, 30)
        default:
            pausedRemaining = nil
        }
        let until = duration.map { Date().addingTimeInterval($0) }
        transition(.pausedByUser(until: until))
    }

    func resume() {
        if let paused = pausedRemaining {
            pausedRemaining = nil
            enterWorking(due: Date().addingTimeInterval(paused.remaining), kind: paused.kind)
        } else {
            scheduleNextBreak(from: Date())
        }
    }

    /// Explicit user command: starts the break even during a context hold.
    func startBreakNow(kind: BreakKind = .short) {
        beginBreak(kind: kind, force: true)
    }

    func skipBreak() {
        guard case .inBreak = state else { return }
        endBreak(completed: false)
    }

    func snooze(_ seconds: TimeInterval = 15 * 60) {
        switch state {
        case .warning(_, let kind), .inBreak(let kind, _):
            enterWorking(due: Date().addingTimeInterval(seconds), kind: kind)
        default: break
        }
    }

#if DEBUG
    /// Test seam: enters heldByContext directly. The real entries are timing-
    /// bound (a due break meeting an active hold), untestable without clock
    /// injection.
    func _testEnterHeld(kind: BreakKind = .short) {
        transition(.heldByContext(kind: kind, overdueSince: Date()))
    }
#endif

    // MARK: - State machine

    /// The single funnel into `.working`: maintains the invariant that
    /// `cycleStartedAt` is always the due date minus the interval, which
    /// `preferencesChanged` relies on to re-derive due dates.
    private func enterWorking(due: Date, kind: BreakKind) {
        cycleStartedAt = due.addingTimeInterval(-prefs.shortInterval)
        transition(.working(nextBreakAt: due, kind: kind))
    }

    private func scheduleNextBreak(from now: Date) {
        guard OfficeHours.isActive(now: now) else {
            transition(.offHours)
            return
        }
        let due = now.addingTimeInterval(prefs.shortInterval)
        enterWorking(due: due, kind: kindForBreak(dueAt: due))
    }

    /// Time-based cadence: a break is long when it lands at least longInterval
    /// after the last completed long break. Works for any short/long ratio.
    /// Static so tests drive the real rule, not a copy.
    static func kind(dueAt: Date, lastLongBreakAt: Date, longInterval: TimeInterval) -> BreakKind {
        dueAt.timeIntervalSince(lastLongBreakAt) >= longInterval ? .long : .short
    }

    private func kindForBreak(dueAt: Date) -> BreakKind {
        Self.kind(dueAt: dueAt, lastLongBreakAt: lastLongBreakAt, longInterval: prefs.longInterval)
    }

    /// An overdue break re-enters through a short grace warning.
    private func warnSoon(kind: BreakKind) {
        enterWarning(breakAt: Date().addingTimeInterval(Self.overdueGrace), kind: kind)
    }

    private func enterWarning(breakAt: Date, kind: BreakKind) {
        // A hold active at the warning moment suppresses the pill too, not
        // just the break (contextChanged only catches holds that *begin*
        // during the warning).
        if context.shouldHold {
            transition(.heldByContext(kind: kind, overdueSince: breakAt))
            return
        }
        transition(.warning(breakAt: breakAt, kind: kind))
    }

    private func beginBreak(kind: BreakKind, force: Bool = false) {
        if context.shouldHold, !force {
            transition(.heldByContext(kind: kind, overdueSince: Date()))
            return
        }
        let duration = kind == .long ? prefs.longDuration : prefs.shortDuration
        transition(.inBreak(kind: kind, endsAt: Date().addingTimeInterval(duration)))
        if prefs.playSounds { NSSound(named: "Glass")?.play() }
    }

    private func endBreak(completed: Bool) {
        if case .inBreak(let kind, _) = state, kind == .long, completed {
            lastLongBreakAt = Date()
        }
        if completed, prefs.playSounds { NSSound(named: "Blow")?.play() }
        scheduleNextBreak(from: Date())
    }

    /// Every state change funnels through here: persist, re-arm the timer,
    /// and reconcile the two imperative UI surfaces with the new state. The
    /// menu bar needs nothing — it derives from `state` via @Observable.
    private func transition(_ new: State) {
        state = new
        persistSnapshot()
        armTimer()
        syncUI()
    }

    private func syncUI() {
        if case .warning(let breakAt, _) = state {
            warningPill?.show(breakAt: breakAt)
        } else {
            warningPill?.hide()
        }
        switch state {
        case .warning, .working:
            break // glow lifecycle handled by evaluate()/glow window entry
        default:
            ambientGlow?.hide()
        }
        if case .inBreak = state { ambientGlow?.hide() }
        if case .inBreak(let kind, let endsAt) = state {
            overlayController?.show(kind: kind, endsAt: endsAt)
        } else {
            overlayController?.hide()
        }
    }

    // MARK: - Session resume

    private struct Snapshot: Codable {
        var savedAt: Date
        var lastLongBreakAt: Date?
        var workingDueAt: Date?
        var workingKind: BreakKind?
    }

    private static let snapshotEncoder = JSONEncoder()

    private func persistSnapshot() {
        var snap = Snapshot(savedAt: Date(), lastLongBreakAt: lastLongBreakAt)
        if case .working(let due, let kind) = state {
            snap.workingDueAt = due
            snap.workingKind = kind
        }
        if let data = try? Self.snapshotEncoder.encode(snap) {
            Defaults.store.set(data, forKey: "engineSnapshot")
        }
    }

    private func restoreSnapshot() -> Bool {
        guard let data = Defaults.store.data(forKey: "engineSnapshot"),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        if let last = snap.lastLongBreakAt { lastLongBreakAt = last }
        // Resume the working countdown only if it's still meaningful: saved
        // recently, due in the future, and inside office hours (the schedule
        // gate must hold on restore too, or a pre-close countdown can fire an
        // overlay after hours).
        if let due = snap.workingDueAt, let kind = snap.workingKind,
           due > Date(), Date().timeIntervalSince(snap.savedAt) < prefs.shortInterval,
           OfficeHours.isActive() {
            enterWorking(due: due, kind: kind)
            return true
        }
        return false
    }

    // MARK: - Preferences

    private func preferencesChanged() {
        if prefs.idleEnabled {
            idleMonitor.start()
        } else {
            idleMonitor.stop()
            // Disabling idle detection while away would strand .idle forever
            // (its only exit is the monitor's return callback).
            if case .idle = state { scheduleNextBreak(from: Date()) }
        }

        switch state {
        case .working(let currentDue, let kind):
            // Re-derive the due date from the cycle start so changing the
            // interval respects time already worked. Unrelated preference
            // changes produce the same due date and are ignored.
            let newDue = cycleStartedAt.addingTimeInterval(prefs.shortInterval)
            if abs(newDue.timeIntervalSince(currentDue)) > 1 {
                if newDue > Date() {
                    enterWorking(due: newDue, kind: kind)
                } else {
                    // New interval is already exceeded: warn, then break.
                    warnSoon(kind: kind)
                }
            }
        case .offHours:
            officeHoursChanged() // office hours may have been disabled/changed
        default:
            break
        }
    }

    // MARK: - The one timer

    private func armTimer() {
        timer?.cancel()
        timer = nil

        let (fireAt, leeway): (Date?, DispatchTimeInterval) = {
            switch state {
            case .working(let due, _):
                let lead = max(prefs.warnLead, prefs.ambientGlowEnabled ? TimeInterval(prefs.ambientGlowLeadSec) : 0)
                let warnAt = due.addingTimeInterval(-lead)
                return (warnAt > Date() ? warnAt : due, .seconds(5))
            case .warning(let breakAt, _):
                return (breakAt, .milliseconds(500))
            case .inBreak(_, let endsAt):
                return (endsAt, .milliseconds(500))
            case .pausedByUser(let until):
                return (until, .seconds(10))
            case .heldByContext:
                return (nil, .seconds(0)) // released by contextChanged()
            case .idle:
                return (nil, .seconds(0)) // released by IdleMonitor / unlock
            case .offHours:
                return (OfficeHours.nextBoundary(), .seconds(30))
            }
        }()

        guard let fireAt else { return } // indefinite pause: no timer at all

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + max(0, fireAt.timeIntervalSinceNow), leeway: leeway)
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        timer = t
    }

    /// The single rule table: given the wall clock, advance whatever is due.
    /// Called by the timer, on wake, and whenever stored dates may have been
    /// overtaken by reality.
    private func evaluate() {
        let now = Date()
        switch state {
        case .working(let due, let kind):
            let warnAt = due.addingTimeInterval(-prefs.warnLead)
            let glowAt = due.addingTimeInterval(-TimeInterval(prefs.ambientGlowLeadSec))
            if now >= due {
                beginBreak(kind: kind)
            } else if now >= warnAt {
                enterWarning(breakAt: due, kind: kind)
            } else {
                if prefs.ambientGlowEnabled, now >= glowAt, !context.shouldHold {
                    ambientGlow?.show(breakAt: due)
                }
                armTimer()
            }
        case .warning(let breakAt, let kind):
            if now >= breakAt { beginBreak(kind: kind) } else { armTimer() }
        case .inBreak(_, let endsAt):
            if now >= endsAt { endBreak(completed: true) } else { armTimer() }
        case .pausedByUser(let until):
            if let until, now >= until { resume() } else { armTimer() }
        case .heldByContext:
            if !context.shouldHold { contextChanged() }
        case .idle:
            break // exits via IdleMonitor.onReturned / systemCameBack
        case .offHours:
            officeHoursChanged()
        }
    }
}
