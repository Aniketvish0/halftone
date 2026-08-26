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

    private let prefs = Preferences.shared
    private var timer: DispatchSourceTimer?

    var overlayController: OverlayController?
    var warningPill: WarningPillController?
    var ambientGlow: AmbientGlowController?
    var microReminders: MicroReminders?
    let menuBarModel = MenuBarModel()
    let context = ContextEngine()
    let presence = PresenceMonitor()

    init() {
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        context.onChange = { [weak self] in
            guard let self else { return }
            self.contextChanged()
            // Hold changes rarely transition; the gate and display must
            // still update.
            self.microReminders?.setActive(self.allowsMicroReminders)
            self.publishDisplay()
        }

        presence.isSuppressed = { [weak self] in
            guard let self else { return false }
            // Sitting still during a break IS the break, not absence.
            if case .inBreak = self.state { return true }
            // Raw engagement, not hold toggles: sitting still on a call or
            // watching is not "away" regardless of break preferences.
            return self.context.isEngaged
        }
        presence.onChange = { [weak self] old, new in
            self?.presenceChanged(from: old, to: new)
        }
        // Presence starts in start(), after state restore.
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
            if context.shouldHold, due.timeIntervalSinceNow < prefs.warnLead {
                transition(.heldByContext(kind: kind, overdueSince: due))
            } else {
                // Hold began or cleared mid-window without a transition:
                // re-derive the glow either way.
                syncGlow(due: due)
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

    // MARK: - Presence integration (single owner: PresenceMonitor)

    private func presenceChanged(from old: Presence, to new: Presence) {
        switch (old.isAway, new.isAway) {
        case (false, true):
            enterIdle(since: { if case .away(let s, _) = new { return s } ; return Date() }())
        case (true, false):
            if presence.lastAwayWasCancelled {
                idleCancelled()
            } else if case .away(let since, _) = old {
                returnedFromIdle(after: Date().timeIntervalSince(since))
            }
            // Desync backstop: if the engine holds a past-due date after
            // the helpers ran (e.g. a pause expired mid-absence and the due
            // passed during sleep), credit the absence and re-enter through
            // the grace warning; never slam an overlay on sit-down.
            if case .working(let due, let kind) = state, due <= Date() {
                if case .away(let since, _) = old,
                   Date().timeIntervalSince(since) >= prefs.longDuration {
                    lastLongBreakAt = Date()
                }
                warnSoon(kind: kind)
            }
        default:
            break
        }
    }

    /// Captures the interrupted countdown (if any) so a short absence can
    /// restore it.
    private func enterIdle(since: Date) {
        switch state {
        case .working(let due, let kind), .warning(let due, let kind):
            transition(.idle(since: since, pending: PendingBreak(dueAt: due, kind: kind)))
        case .heldByContext(let kind, let overdueSince):
            transition(.idle(since: since, pending: PendingBreak(dueAt: overdueSince, kind: kind)))
        case .inBreak(let kind, _):
            // Only lock/sleep reach here (hidIdle is suppressed in-break).
            // Locking mid-break is taking the break: credit it and go idle
            // directly, with no intermediate .working transition and no
            // completion chime into an empty room.
            if kind == .long { lastLongBreakAt = Date() }
            transition(.idle(since: since, pending: nil))
        case .pausedByUser, .idle, .offHours:
            break // paused stays paused; already idle; off-hours has no cycle
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

    /// The away call was wrong (engagement with no input). Restore exactly
    /// what was interrupted; never a fresh cycle.
    private func idleCancelled() {
        guard case .idle(_, let pending) = state else { return }
        if let pending {
            if pending.dueAt > Date() {
                enterWorking(due: pending.dueAt, kind: pending.kind)
            } else {
                warnSoon(kind: pending.kind)
            }
        } else {
            scheduleNextBreak(from: Date())
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
        // Presence starts AFTER the engine has a real state: starting it in
        // init raced restore and desynced monitor/engine on every cold boot.
        if prefs.idleEnabled { presence.start() }
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

    /// Test seams for the idle paths (the real entries need HID idle time).
    func _testEnterIdle(pending: PendingBreak?) {
        transition(.idle(since: Date(), pending: pending))
    }
    func _testIdleCancelled() { idleCancelled() }
    func _testReturnedFromIdle(after away: TimeInterval) { returnedFromIdle(after: away) }
#endif

    // MARK: - State machine

    /// The single funnel into `.working`: maintains the invariant that
    /// `cycleStartedAt` is always the due date minus the interval, which
    /// `preferencesChanged` relies on to re-derive due dates.
    private func enterWorking(due: Date, kind: BreakKind) {
        cycleStartedAt = due.addingTimeInterval(-prefs.shortInterval)
        typingRetries = 0
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

    /// Mid-keystroke or mid-drag deferral window. Checked only at the fire
    /// moment (no event monitoring, no permissions): if the last keydown or
    /// drag is fresher than this, wait briefly and re-check.
    private static let typingHoldWindow: TimeInterval = 3
    /// Max deferrals before the break fires anyway. A user in Claude Code
    /// types continuously, so without a ceiling the break defers forever in
    /// 5-second loops, showing a frozen "20m" countdown the whole time.
    static let maxTypingRetries = 3
    private var typingRetries = 0

    private func beginBreak(kind: BreakKind, force: Bool = false) {
        if context.shouldHold, !force {
            transition(.heldByContext(kind: kind, overdueSince: Date()))
            return
        }
        if !force, typingRetries < Self.maxTypingRetries, Self.userIsMidInput() {
            typingRetries += 1
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 5, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.evaluate() }
            t.resume()
            timer = t
            publishDisplay() // update the countdown from "20m" to the real remaining
            return
        }
        typingRetries = 0
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
    private var isTransitioning = false

    private func transition(_ new: State) {
        // syncUI side effects can synchronously re-enter via workspace
        // notifications; defer nested transitions one turn.
        guard !isTransitioning else {
            DispatchQueue.main.async { [weak self] in self?.transition(new) }
            return
        }
        isTransitioning = true
        defer { isTransitioning = false }

        let old = state
        state = new
        persistSnapshot()
        armTimer()
        syncUI()
        fireHooks(from: old, to: new)
    }

    /// Shell hooks on the transitions users script against. Deliberately
    /// edge-triggered (state class changes, not re-arms within a state).
    private enum StateClass {
        case working, warning, inBreak, paused, held, idle, offHours

        init(_ s: State) {
            switch s {
            case .working: self = .working
            case .warning: self = .warning
            case .inBreak: self = .inBreak
            case .pausedByUser: self = .paused
            case .heldByContext: self = .held
            case .idle: self = .idle
            case .offHours: self = .offHours
            }
        }
    }

    private func fireHooks(from old: State, to new: State) {
        let (o, n) = (StateClass(old), StateClass(new))
        guard o != n else { return }
        switch n {
        case .warning: EventHooks.shared.fire("break-warning")
        case .inBreak:
            if case .inBreak(let kind, _) = new {
                EventHooks.shared.fire("break-start", context: ["kind": kind.rawValue])
            }
        case .held:
            EventHooks.shared.fire("hold-start",
                                   context: ["reasons": context.holdReasonsSummary])
        case .idle: EventHooks.shared.fire("idle-start")
        default: break
        }
        switch o {
        case .inBreak: EventHooks.shared.fire("break-end")
        case .held: EventHooks.shared.fire("hold-end")
        case .idle: EventHooks.shared.fire("idle-end")
        default: break
        }
    }

    /// Single owner of the glow: visible iff enabled, inside the window,
    /// no hold. show() is idempotent per target, so calling this on every
    /// settle is safe.
    private func syncGlow(due: Date) {
        let glowAt = due.addingTimeInterval(-TimeInterval(prefs.ambientGlowLeadSec))
        if prefs.ambientGlowEnabled, Date() >= glowAt, !context.shouldHold {
            ambientGlow?.show(breakAt: due)
        } else {
            ambientGlow?.hide()
        }
    }

    /// True while the user is actively typing or dragging (checked on
    /// demand; CGEventSource reads need no permissions).
    static func userIsMidInput() -> Bool {
        let keys = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let drag = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDragged)
        return min(keys, drag) < typingHoldWindow
    }

    /// Micro-reminders only interrupt plain working time, never over a
    /// break, a warning, a hold, or an absence.
    var allowsMicroReminders: Bool {
        if context.shouldHold { return false }
        if case .working = state { return true }
        return false
    }

    private func syncUI() {
        if case .warning(let breakAt, _) = state {
            warningPill?.show(breakAt: breakAt)
        } else {
            warningPill?.hide()
        }
        switch state {
        case .working(let due, _), .warning(let due, _):
            syncGlow(due: due)
        default:
            ambientGlow?.hide()
        }
        microReminders?.setActive(allowsMicroReminders)
        if case .inBreak(let kind, let endsAt) = state {
            overlayController?.show(kind: kind, endsAt: endsAt)
        } else {
            overlayController?.hide()
        }
        publishDisplay()
    }

    /// Single writer of the menu bar model; runs on every transition and
    /// context change.
    private func publishDisplay() {
        let display = MenuBarDisplay.compute(
            state: state,
            shouldHold: context.shouldHold,
            holdReasons: context.holdReasons,
            showCountdown: prefs.showCountdownInMenuBar,
            now: Date())
        let statusLine: String? = {
            switch state {
            case .heldByContext:
                return "Holding: \(context.holdReasonsSummary)"
            case .working, .warning:
                guard context.shouldHold else { return nil }
                return "Will hold: \(context.holdReasonsSummary)"
            case .idle: return "Away, time counts as your break"
            case .offHours: return "Outside office hours"
            case .pausedByUser(let until):
                if let until {
                    return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
                }
                return "Paused"
            default: return nil
            }
        }()
        menuBarModel.update(display: display, statusLine: statusLine)
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
        switch state {
        case .working(let due, let kind):
            snap.workingDueAt = due
            snap.workingKind = kind
        case .idle(_, let pending?):
            // Keep the in-flight cycle across lock-then-shutdown.
            snap.workingDueAt = pending.dueAt
            snap.workingKind = pending.kind
        default:
            break
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
           OfficeHours.isActive() {
            let awayDuration = Date().timeIntervalSince(snap.savedAt)
            if due > Date(), awayDuration < prefs.shortInterval {
                // Due in the future and saved recently: resume the countdown.
                enterWorking(due: due, kind: kind)
                return true
            }
            // Past-due or stale: credit the absence, start fresh.
            if awayDuration >= prefs.longDuration {
                lastLongBreakAt = Date()
            }
            scheduleNextBreak(from: Date())
            return true
        }
        return false
    }

    // MARK: - Preferences

    private func preferencesChanged() {
        if prefs.idleEnabled {
            presence.start()
        } else {
            presence.stop()
            // Disabling idle detection while away would strand .idle forever
            // (its only exit is the monitor's callback).
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
            } else {
                // Due unchanged, but glow enable/lead may have changed:
                // re-derive the glow now and re-arm for any new milestone.
                syncGlow(due: currentDue)
                armTimer()
            }
        case .warning(let breakAt, _):
            syncGlow(due: breakAt)
            armTimer()
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
                // Earliest still-future milestone: glow start, then warning,
                // then the break. Collapsing these into one wake (the old
                // max(lead) form) skipped the warning pill whenever the glow
                // lead exceeded the warn lead.
                let now = Date()
                let warnAt = due.addingTimeInterval(-prefs.warnLead)
                let glowAt = prefs.ambientGlowEnabled
                    ? due.addingTimeInterval(-TimeInterval(prefs.ambientGlowLeadSec)) : .distantPast
                return ([glowAt, warnAt, due].filter { $0 > now }.min() ?? due, .seconds(5))
            case .warning(let breakAt, _):
                // The glow moment can land inside .warning (glow lead shorter
                // than warn lead): wake for it, not only for the break.
                let now = Date()
                let glowAt = prefs.ambientGlowEnabled
                    ? breakAt.addingTimeInterval(-TimeInterval(prefs.ambientGlowLeadSec)) : .distantPast
                if glowAt > now { return (glowAt, .seconds(2)) }
                return (breakAt, .milliseconds(500))
            case .inBreak(_, let endsAt):
                return (endsAt, .milliseconds(500))
            case .pausedByUser(let until):
                return (until, .seconds(10))
            case .heldByContext:
                return (nil, .seconds(0)) // released by contextChanged()
            case .idle:
                return (nil, .seconds(0)) // released by PresenceMonitor
            case .offHours:
                return (OfficeHours.nextBoundary(), .seconds(30))
            }
        }()

        guard let fireAt else { return } // indefinite pause: no timer at all

        let t = DispatchSource.makeTimerSource(queue: .main)
        // Wall clock, not CPU clock: deadline-based timers suspend during
        // sleep, so a due date passing mid-sleep left a stale .working with
        // a hidden countdown until the suspended timer finally caught up.
        t.schedule(wallDeadline: .now() + max(0, fireAt.timeIntervalSinceNow), leeway: leeway)
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
            if now >= due {
                beginBreak(kind: kind)
            } else if now >= warnAt {
                enterWarning(breakAt: due, kind: kind)
            } else {
                syncGlow(due: due)
                armTimer()
            }
        case .warning(let breakAt, let kind):
            if now >= breakAt {
                beginBreak(kind: kind)
            } else {
                syncGlow(due: breakAt)
                armTimer()
            }
        case .inBreak(_, let endsAt):
            if now >= endsAt { endBreak(completed: true) } else { armTimer() }
        case .pausedByUser(let until):
            if let until, now >= until { resume() } else { armTimer() }
        case .heldByContext:
            if !context.shouldHold { contextChanged() }
        case .idle:
            break // exits via presenceChanged
        case .offHours:
            officeHoursChanged()
        }
    }
}
