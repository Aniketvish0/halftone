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
        /// User stepped away; time away counts as their break.
        case idle(since: Date)
        /// Outside configured office hours; scheduling suspended.
        case offHours
    }

    private(set) var state: State = .pausedByUser(until: nil)

    /// Long-break cadence: every Nth completed short-cycle becomes a long break.
    private var shortBreaksSinceLong = 0

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
            MainActor.assumeIsolated { self?.revalidate() }
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
        case .heldByContext(let kind, let overdueSince):
            if !context.shouldHold {
                // Hold cleared. Fire the overdue break after a short grace
                // (let the user breathe after their call).
                let grace = Date().addingTimeInterval(15)
                _ = overdueSince
                transition(.warning(breakAt: grace, kind: kind))
                warningPill?.show(breakAt: grace)
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
        switch state {
        case .working, .warning, .heldByContext:
            warningPill?.hide()
            transition(.idle(since: Date()))
        case .inBreak:
            // Away during a break = taking the break; let it complete naturally.
            break
        default:
            break
        }
    }

    private func returnedFromIdle(after away: TimeInterval) {
        guard case .idle = state else { return }
        // Away long enough to count as a full break resets the cycle; a
        // shorter absence still counts: push the next break out by it.
        if away >= prefs.shortDuration {
            shortBreaksSinceLong += away >= prefs.longDuration ? 0 : 1
            if away >= prefs.longDuration { shortBreaksSinceLong = 0 }
            scheduleNextBreak(from: Date())
        } else {
            scheduleNextBreak(from: Date().addingTimeInterval(away - prefs.shortInterval < 0 ? away : 0))
        }
    }

    private func systemWentAway() {
        if awaySince == nil { awaySince = Date() }
        if case .inBreak = state { return }
        if case .pausedByUser = state { return }
        warningPill?.hide()
        overlayController?.hide()
        transition(.idle(since: awaySince ?? Date()))
    }

    private func systemCameBack() {
        guard let since = awaySince else { return }
        awaySince = nil
        if case .idle = state {
            returnedFromIdle(after: Date().timeIntervalSince(since))
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
        let until = duration.map { Date().addingTimeInterval($0) }
        transition(.pausedByUser(until: until))
    }

    func resume() {
        scheduleNextBreak(from: Date())
    }

    func startBreakNow(kind: BreakKind = .short) {
        beginBreak(kind: kind)
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
            transition(.working(nextBreakAt: Date().addingTimeInterval(seconds), kind: kind))
        default: break
        }
    }

    // MARK: - State machine

    private func scheduleNextBreak(from now: Date) {
        guard OfficeHours.isActive(now: now) else {
            transition(.offHours)
            return
        }
        let isLong = shortBreaksSinceLong + 1 >= max(1, prefs.longIntervalMin / max(1, prefs.shortIntervalMin))
        let kind: BreakKind = isLong ? .long : .short
        let due = now.addingTimeInterval(prefs.shortInterval)
        transition(.working(nextBreakAt: due, kind: kind))
    }

    private func enterWarning(breakAt: Date, kind: BreakKind) {
        transition(.warning(breakAt: breakAt, kind: kind))
        warningPill?.show(breakAt: breakAt)
    }

    private func beginBreak(kind: BreakKind) {
        if context.shouldHold {
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
        if case .inBreak(let kind, _) = state {
            if kind == .long { shortBreaksSinceLong = 0 }
            else if completed { shortBreaksSinceLong += 1 }
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
        var shortBreaksSinceLong: Int
        var workingDueAt: Date?
        var workingKind: BreakKind?
    }

    private func persistSnapshot() {
        var snap = Snapshot(savedAt: Date(), shortBreaksSinceLong: shortBreaksSinceLong)
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
        shortBreaksSinceLong = snap.shortBreaksSinceLong
        // Resume the working countdown only if it's still meaningful:
        // saved recently and the due date is in the future.
        if let due = snap.workingDueAt, let kind = snap.workingKind,
           due > Date(), Date().timeIntervalSince(snap.savedAt) < prefs.shortInterval {
            transition(.working(nextBreakAt: due, kind: kind))
            return true
        }
        return false
    }

    /// Called on wake / preference change: re-derive where we should be from Dates.
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
            if let until, now >= until { scheduleNextBreak(from: now) } else { armTimer() }
        case .heldByContext:
            if !context.shouldHold { contextChanged() } else { armTimer() }
        case .idle:
            armTimer()
        case .offHours:
            officeHoursChanged()
        }
    }

    private func preferencesChanged() {
        if prefs.idleEnabled { idleMonitor.start() } else { idleMonitor.stop() }
        switch state {
        case .working:
            scheduleNextBreak(from: Date())
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
                return (nil, .seconds(0)) // released by IdleMonitor
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
            if let until, now >= until { scheduleNextBreak(from: now) } else { armTimer() }
        case .heldByContext, .idle:
            break
        case .offHours:
            officeHoursChanged()
        }
    }
}
