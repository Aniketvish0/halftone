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

    private let prefs = Preferences.shared
    private var timer: DispatchSourceTimer?

    var overlayController: OverlayController?
    var warningPill: WarningPillController?
    let context = ContextEngine()
    private let idleMonitor = IdleMonitor()

    init() {
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        // Sleep/wake correctness: recompute from wall clock on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWoke() }
        }

        context.onChange = { [weak self] in self?.contextChanged() }

        idleMonitor.isSuppressed = { [weak self] in
            // Watching a video with hands off the keyboard is not "away".
            self?.context.activeFlags.contains(.mediaPlaying) ?? false
        }
        idleMonitor.onWentIdle = { [weak self] in self?.wentIdle() }
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

    private var awaySince: Date?

    // MARK: - Context (Smart Pause) integration

    private func contextChanged() {
        switch state {
        case .warning(let breakAt, let kind):
            if context.shouldHold {
                // Cancel the imminent break; it fires when the hold clears.
                warningPill?.hide()
                transition(.heldByContext(kind: kind, overdueSince: breakAt))
            }
        case .working(let due, let kind):
            if context.shouldHold, due.timeIntervalSinceNow < prefs.warnLead {
                transition(.heldByContext(kind: kind, overdueSince: due))
            }
        case .heldByContext(let kind, _):
            if !context.shouldHold {
                // Hold cleared. Fire the overdue break after a short grace
                // (let the user breathe after their call).
                enterWarning(breakAt: Date().addingTimeInterval(15), kind: kind)
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

    private func wentIdle() {
        guard prefs.idleEnabled else { return }
        enterIdle(since: Date())
    }

    /// Captures the interrupted countdown (if any) so a short absence can
    /// restore it. Used by both idle detection and lock/sleep.
    private func enterIdle(since: Date) {
        let pending: PendingBreak? = {
            switch state {
            case .working(let due, let kind), .warning(let due, let kind):
                return PendingBreak(dueAt: due, kind: kind)
            case .heldByContext(let kind, let overdueSince):
                return PendingBreak(dueAt: overdueSince, kind: kind)
            default:
                return nil
            }
        }()
        switch state {
        case .working, .warning, .heldByContext:
            warningPill?.hide()
            transition(.idle(since: since, pending: pending))
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
                cycleStartedAt = pending.dueAt.addingTimeInterval(-prefs.shortInterval)
                transition(.working(nextBreakAt: pending.dueAt, kind: pending.kind))
            } else {
                // Came due while away: warn now, then break.
                enterWarning(breakAt: Date().addingTimeInterval(15), kind: pending.kind)
            }
        } else {
            scheduleNextBreak(from: Date())
        }
    }

    private func systemWentAway() {
        if awaySince == nil { awaySince = Date() }
        if case .inBreak = state { return }
        if case .pausedByUser = state { return }
        overlayController?.hide()
        warningPill?.hide()
        enterIdle(since: awaySince ?? Date())
    }

    private func systemCameBack() {
        guard let since = awaySince else { return }
        awaySince = nil
        if case .idle = state {
            returnedFromIdle(after: Date().timeIntervalSince(since))
        }
    }

    /// Wake without a lock (no password after sleep, auto-login) never posts
    /// screenIsUnlocked — treat wake itself as the return unless the screen is
    /// actually still locked, in which case the unlock notification finishes.
    private func systemWoke() {
        if awaySince != nil, !Self.screenIsLocked() {
            systemCameBack()
        } else {
            revalidate()
        }
    }

    private static func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
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
            if !active {
                warningPill?.hide()
                transition(.offHours)
            }
        }
    }

    // MARK: - Public controls

    func start() {
        if !restoreSnapshot() {
            scheduleNextBreak(from: Date())
        }
    }

    func pause(for duration: TimeInterval? = nil) {
        warningPill?.hide()
        overlayController?.hide()
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
            let due = Date().addingTimeInterval(paused.remaining)
            cycleStartedAt = due.addingTimeInterval(-prefs.shortInterval)
            transition(.working(nextBreakAt: due, kind: paused.kind))
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
            warningPill?.hide()
            overlayController?.hide()
            let due = Date().addingTimeInterval(seconds)
            cycleStartedAt = due.addingTimeInterval(-prefs.shortInterval)
            transition(.working(nextBreakAt: due, kind: kind))
        default: break
        }
    }

    // MARK: - State machine

    private func scheduleNextBreak(from now: Date) {
        guard OfficeHours.isActive(now: now) else {
            transition(.offHours)
            return
        }
        cycleStartedAt = now
        let due = now.addingTimeInterval(prefs.shortInterval)
        transition(.working(nextBreakAt: due, kind: kindForBreak(dueAt: due)))
    }

    /// Time-based cadence: a break is long when it lands at least longInterval
    /// after the last completed long break. Works for any short/long ratio.
    private func kindForBreak(dueAt: Date) -> BreakKind {
        dueAt.timeIntervalSince(lastLongBreakAt) >= prefs.longInterval ? .long : .short
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
        warningPill?.show(breakAt: breakAt)
    }

    private func beginBreak(kind: BreakKind, force: Bool = false) {
        if context.shouldHold, !force {
            transition(.heldByContext(kind: kind, overdueSince: Date()))
            return
        }
        let duration = kind == .long ? prefs.longDuration : prefs.shortDuration
        let endsAt = Date().addingTimeInterval(duration)
        warningPill?.hide()
        transition(.inBreak(kind: kind, endsAt: endsAt))
        overlayController?.show(kind: kind, endsAt: endsAt)
        if prefs.playSounds { NSSound(named: "Glass")?.play() }
    }

    private func endBreak(completed: Bool) {
        if case .inBreak(let kind, _) = state, kind == .long, completed {
            lastLongBreakAt = Date()
        }
        overlayController?.hide()
        if completed, prefs.playSounds { NSSound(named: "Blow")?.play() }
        scheduleNextBreak(from: Date())
    }

    private func transition(_ new: State) {
        state = new
        persistSnapshot()
        armTimer()
    }

    // MARK: - Session resume

    private struct Snapshot: Codable {
        var savedAt: Date
        var lastLongBreakAt: Date?
        var workingDueAt: Date?
        var workingKind: BreakKind?
    }

    private func persistSnapshot() {
        var snap = Snapshot(savedAt: Date(), lastLongBreakAt: lastLongBreakAt)
        if case .working(let due, let kind) = state {
            snap.workingDueAt = due
            snap.workingKind = kind
        }
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: "engineSnapshot")
        }
    }

    private func restoreSnapshot() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "engineSnapshot"),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        if let last = snap.lastLongBreakAt { lastLongBreakAt = last }
        // Resume the working countdown only if it's still meaningful: saved
        // recently, due in the future, and inside office hours (the schedule
        // gate must hold on restore too, or a pre-close countdown can fire an
        // overlay after hours).
        if let due = snap.workingDueAt, let kind = snap.workingKind,
           due > Date(), Date().timeIntervalSince(snap.savedAt) < prefs.shortInterval,
           OfficeHours.isActive() {
            cycleStartedAt = due.addingTimeInterval(-prefs.shortInterval)
            transition(.working(nextBreakAt: due, kind: kind))
            return true
        }
        return false
    }

    /// Re-derive where we should be from stored Dates (wake, hold release).
    private func revalidate() {
        let now = Date()
        switch state {
        case .working(let due, let kind):
            if now >= due { beginBreak(kind: kind) } else { armTimer() }
        case .warning(let breakAt, let kind):
            if now >= breakAt { beginBreak(kind: kind) } else { armTimer() }
        case .inBreak(_, let endsAt):
            if now >= endsAt { endBreak(completed: true) } else { armTimer() }
        case .pausedByUser(let until):
            if let until, now >= until { resume() } else { armTimer() }
        case .heldByContext:
            if !context.shouldHold { contextChanged() } else { armTimer() }
        case .idle:
            armTimer()
        case .offHours:
            officeHoursChanged()
        }
    }

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
        case .working(_, let kind):
            // Re-derive the due date from the cycle start so changing the
            // interval respects time already worked. Unrelated preference
            // changes produce the same due date and are ignored — the old
            // behavior restarted the countdown on every Settings tweak.
            let newDue = cycleStartedAt.addingTimeInterval(prefs.shortInterval)
            let current: Date? = { if case .working(let d, _) = state { return d } ; return nil }()
            if let current, abs(newDue.timeIntervalSince(current)) > 1 {
                if newDue > Date() {
                    transition(.working(nextBreakAt: newDue, kind: kind))
                } else {
                    // New interval is already exceeded: warn, then break.
                    enterWarning(breakAt: Date().addingTimeInterval(15), kind: kind)
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
                let warnAt = due.addingTimeInterval(-prefs.warnLead)
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
        let delta = max(0, fireAt.timeIntervalSinceNow)
        t.schedule(deadline: .now() + delta, leeway: leeway)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.fire()
        }
        t.resume()
        timer = t
    }

    private func fire() {
        let now = Date()
        switch state {
        case .working(let due, let kind):
            let warnAt = due.addingTimeInterval(-prefs.warnLead)
            if now >= due {
                beginBreak(kind: kind)
            } else if now >= warnAt {
                enterWarning(breakAt: due, kind: kind)
            } else {
                armTimer()
            }
        case .warning(let breakAt, let kind):
            if now >= breakAt { beginBreak(kind: kind) } else { armTimer() }
        case .inBreak(_, let endsAt):
            if now >= endsAt { endBreak(completed: true) } else { armTimer() }
        case .pausedByUser(let until):
            if let until, now >= until { resume() } else { armTimer() }
        case .heldByContext, .idle:
            break
        case .offHours:
            officeHoursChanged()
        }
    }
}
