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
    }

    private(set) var state: State = .pausedByUser(until: nil)

    /// Long-break cadence: every Nth completed short-cycle becomes a long break.
    private var shortBreaksSinceLong = 0

    private let prefs = Preferences.shared
    private var timer: DispatchSourceTimer?

    var overlayController: OverlayController?
    var warningPill: WarningPillController?

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
    }

    // MARK: - Public controls

    func start() {
        scheduleNextBreak(from: Date())
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
        armTimer()
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
        }
    }

    private func preferencesChanged() {
        // Keep it simple in P1: if working, re-derive the due date from now.
        if case .working = state { scheduleNextBreak(from: Date()) }
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
        }
    }
}
