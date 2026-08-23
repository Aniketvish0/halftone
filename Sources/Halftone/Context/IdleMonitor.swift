import Foundation
import CoreGraphics

/// Watches for the user stepping away. No 1-second polling: schedules the
/// next check exactly at (lastInput + threshold), re-arming as input arrives.
/// While away, polls at 2s for the return. "Watching video" (media flag)
/// suppresses idle — zero HID input while watching a movie is not "away".
@MainActor
final class IdleMonitor {
    var onWentIdle: (() -> Void)?
    /// Passes how long the user was away. Fresh input = a real return.
    var onReturned: ((TimeInterval) -> Void)?
    /// The idle call was WRONG (engagement appeared with no input: the user
    /// was on a call/watching all along). Not a return: no break crediting.
    var onIdleCancelled: (() -> Void)?
    /// Consulted before declaring idle (e.g. media playing = not away).
    var isSuppressed: (() -> Bool)?

    private var idleStartedAt: Date?
    var isIdle: Bool { idleStartedAt != nil }
    private var timer: DispatchSourceTimer?
    private var running = false

    private var threshold: TimeInterval {
        TimeInterval(Preferences.shared.idleThresholdSec)
    }

    static func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func start() {
        guard !running else { return }
        running = true
        scheduleNextCheck()
    }

    func stop() {
        running = false
        timer?.cancel(); timer = nil
        idleStartedAt = nil
    }

    private func scheduleNextCheck() {
        guard running else { return }

        let idle = Self.secondsSinceLastInput()

        if let start = idleStartedAt {
            if idle < 2 {
                // Fresh input: a real return.
                idleStartedAt = nil
                onReturned?(Date().timeIntervalSince(start))
                arm(after: max(1, threshold - idle), leeway: .seconds(5))
            } else if isSuppressed?() ?? false {
                // Engagement appeared with no input: the idle call was wrong
                // (they were on a call / watching all along). Retract it
                // WITHOUT crediting a break — the old path routed this
                // through onReturned and restarted the whole cycle.
                idleStartedAt = nil
                onIdleCancelled?()
                arm(after: max(1, threshold - idle), leeway: .seconds(5))
            } else {
                // Poll for return: 2s while freshly away (coffee refill),
                // backing off to 10s for long absences (away accuracy comes
                // from idleStartedAt, so the only cost is return latency).
                let awayFor = Date().timeIntervalSince(start)
                arm(after: awayFor < 60 ? 2 : 10, leeway: .seconds(2))
            }
        } else if idle >= threshold {
            if isSuppressed?() ?? false {
                // Media is playing; the user is watching, not away. Past the
                // threshold "threshold - idle" is <= 0, which would degrade
                // into a 1-second poll for the whole movie. Back off instead:
                // suppression ending matters within ~30s, not within 1s.
                arm(after: 30, leeway: .seconds(10))
            } else {
                idleStartedAt = Date().addingTimeInterval(-idle)
                onWentIdle?()
                arm(after: 2, leeway: .seconds(1))
            }
        } else {
            // Wake exactly when the threshold could first be crossed.
            arm(after: max(1, threshold - idle), leeway: .seconds(5))
        }
    }

    private func arm(after delay: TimeInterval, leeway: DispatchTimeInterval) {
        if let timer {
            timer.schedule(deadline: .now() + delay, leeway: leeway)
        } else {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + delay, leeway: leeway)
            t.setEventHandler { [weak self] in self?.scheduleNextCheck() }
            t.resume()
            timer = t
        }
    }
}
