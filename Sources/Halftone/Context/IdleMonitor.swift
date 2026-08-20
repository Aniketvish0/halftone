import Foundation
import CoreGraphics

/// Watches for the user stepping away. No 1-second polling: schedules the
/// next check exactly at (lastInput + threshold), re-arming as input arrives.
/// While away, polls at 2s for the return. "Watching video" (media flag)
/// suppresses idle — zero HID input while watching a movie is not "away".
@MainActor
final class IdleMonitor {
    var onWentIdle: (() -> Void)?
    /// Passes how long the user was away.
    var onReturned: ((TimeInterval) -> Void)?
    /// Consulted before declaring idle (e.g. media playing = not away).
    var isSuppressed: (() -> Bool)?

    private(set) var isIdle = false
    private var idleStartedAt: Date?
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
        isIdle = false
        idleStartedAt = nil
    }

    private func scheduleNextCheck() {
        guard running else { return }
        timer?.cancel()

        let idle = Self.secondsSinceLastInput()

        if isIdle {
            if idle < 2 {
                // User is back.
                let away = idleStartedAt.map { Date().timeIntervalSince($0) } ?? idle
                isIdle = false
                idleStartedAt = nil
                onReturned?(away)
                arm(after: max(1, threshold - idle), leeway: .seconds(5))
            } else {
                arm(after: 2, leeway: .seconds(1)) // poll for return
            }
        } else {
            if idle >= threshold, !(isSuppressed?() ?? false) {
                isIdle = true
                idleStartedAt = Date().addingTimeInterval(-idle)
                onWentIdle?()
                arm(after: 2, leeway: .seconds(1))
            } else {
                // Wake exactly when the threshold could first be crossed.
                arm(after: max(1, threshold - idle), leeway: .seconds(5))
            }
        }
    }

    private func arm(after delay: TimeInterval, leeway: DispatchTimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay, leeway: leeway)
        t.setEventHandler { [weak self] in self?.scheduleNextCheck() }
        t.resume()
        timer = t
    }
}
