import Foundation
import AppKit
import CoreGraphics

/// Why the user is away. Lock and sleep are stronger evidence than HID
/// silence: they end only when their own condition ends, not on input.
enum AwayReason: Equatable {
    case hidIdle
    case locked
    case asleep
}

enum Presence: Equatable {
    case present
    case away(since: Date, reason: AwayReason)

    var isAway: Bool { if case .away = self { return true }; return false }
}

/// Sole owner of user presence. Lock, sleep, wake, and HID idle are inputs;
/// nothing else may declare the user away or back.
///
/// Invariant: every away state carries its own poll backstop. Notifications
/// accelerate transitions; no transition depends on one being delivered.
@MainActor
final class PresenceMonitor {
    private(set) var presence: Presence = .present

    /// Single transition callback. `previous` lets the consumer distinguish
    /// return-from-away (credit a break) from cancellation (restore).
    var onChange: ((_ old: Presence, _ new: Presence) -> Void)?

    /// Consulted before declaring HID idleness (a call or video with hands
    /// off the keyboard is not "away"). Never consulted for lock/sleep:
    /// a locked screen is away regardless of what audio plays.
    var isSuppressed: (() -> Bool)?

    /// True when the HID-idle away was retracted because engagement appeared
    /// with no input (set for the transition delivered to onChange).
    private(set) var lastAwayWasCancelled = false

    private var timer: DispatchSourceTimer?
    private var running = false
    /// Installed only while away: the first mouse or scroll event anywhere on
    /// the system ends the absence in the same runloop turn, instead of
    /// waiting for the next poll. Mouse-class global monitors need no
    /// permission; keyboard-only returns fall back to the poll.
    private var returnMonitor: Any?
    /// What the current poll was armed for, so a late fire is measurable.
    private var armedFor: (at: TimeInterval, delay: TimeInterval)?

#if DEBUG
    var _testHasReturnMonitor: Bool { returnMonitor != nil }
#endif

    private var threshold: TimeInterval {
        TimeInterval(Preferences.shared.idleThresholdSec)
    }

    static func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    static func screenIsLocked() -> Bool {
        CGSession.flag("CGSSessionScreenIsLocked")
    }

    init() {
        // Notifications are accelerators only; the poll backstops correctness.
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(forName: NSWorkspace.willSleepNotification,
                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterAway(.asleep) }
        }
        wsnc.addObserver(forName: NSWorkspace.didWakeNotification,
                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterAway(.locked) }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        // A launch mid-lock (login window relaunch, boot race) must observe
        // the lock, not assume presence.
        if Self.screenIsLocked() {
            enterAway(.locked)
        } else {
            check()
        }
    }

    func stop() {
        running = false
        timer?.cancel(); timer = nil
        removeReturnMonitor()
        presence = .present
        lastAwayWasCancelled = false
    }

    // MARK: - Event-driven return

    private func installReturnMonitor() {
        guard returnMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .scrollWheel,
                                           .leftMouseDragged, .rightMouseDragged]
        returnMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                Trace.mark("presence.inputEvent")
                self?.check()
            }
        }
    }

    private func removeReturnMonitor() {
        if let m = returnMonitor { NSEvent.removeMonitor(m) }
        returnMonitor = nil
    }

#if DEBUG
    /// Test seams. They activate the monitor and then drive the REAL entry
    /// and evaluation paths (a seam that bypasses enterAway's upgrade logic
    /// verifies a copy, not the code).
    func _testEnterAway(_ reason: AwayReason, since: Date = Date()) {
        running = true
        enterAway(reason, at: since)
    }
    func _testCheck(now: Date = Date(), idleSeconds: TimeInterval,
                    locked: Bool) {
        running = true
        evaluate(now: now, idleSeconds: idleSeconds, locked: locked)
    }
#endif

    // MARK: - Transitions

    private func enterAway(_ reason: AwayReason, at entry: Date = Date()) {
        guard running else { return }
        switch presence {
        case .away(_, let current) where strength(current) >= strength(reason):
            break // already away for an equal/stronger reason; keep its since
        case .away(let since, _):
            transition(to: .away(since: since, reason: reason), cancelled: false)
        case .present:
            transition(to: .away(since: entry, reason: reason), cancelled: false)
        }
        armBackstop()
    }

    /// Lock/sleep outrank HID idleness: their exits are condition-based.
    private func strength(_ r: AwayReason) -> Int {
        switch r {
        case .hidIdle: 0
        case .locked: 1
        case .asleep: 1
        }
    }

    private func check() {
        guard running else { return }
        evaluate(now: Date(),
                 idleSeconds: Self.secondsSinceLastInput(),
                 locked: Self.screenIsLocked())
    }

    private func evaluate(now: Date, idleSeconds: TimeInterval, locked: Bool) {
        guard running else { return }
        switch presence {
        case .away(let since, let reason):
            switch reason {
            case .locked, .asleep:
                if locked {
                    armBackstop() // still locked: keep polling
                } else if idleSeconds < 2 {
                    // Unlocked AND typing: definitely back.
                    transition(to: .present, cancelled: false)
                    armThresholdWatch(idleSeconds: idleSeconds)
                } else {
                    // Unlocked but hands still off: away continues, but the
                    // reason decays to hidIdle so the return poll owns it.
                    transition(to: .away(since: since, reason: .hidIdle),
                               cancelled: false, silent: true)
                    armBackstop()
                }
            case .hidIdle:
                if idleSeconds < 2 {
                    transition(to: .present, cancelled: false)
                    armThresholdWatch(idleSeconds: idleSeconds)
                } else if isSuppressed?() ?? false {
                    // Engagement with no input: retract without crediting.
                    transition(to: .present, cancelled: true)
                    armThresholdWatch(idleSeconds: 0)
                } else {
                    armBackstop()
                }
            }
        case .present:
            if locked {
                enterAway(.locked)
            } else if idleSeconds >= threshold {
                if isSuppressed?() ?? false {
                    // Engaged with hands off: not away.
                    arm(after: 30, leeway: .seconds(10))
                } else {
                    transition(to: .away(since: now.addingTimeInterval(-idleSeconds),
                                         reason: .hidIdle), cancelled: false)
                    armBackstop()
                }
            } else {
                armThresholdWatch(idleSeconds: idleSeconds)
            }
        }
    }

    /// `silent` transitions mutate the stored presence without notifying:
    /// used only for the locked->hidIdle reason decay, which is an internal
    /// bookkeeping change, not a user-visible one.
    private func transition(to new: Presence, cancelled: Bool, silent: Bool = false) {
        guard new != presence else { return }
        let old = presence
        presence = new
        lastAwayWasCancelled = cancelled
        // The mouse monitor exists exactly while away.
        if new.isAway { installReturnMonitor() } else { removeReturnMonitor() }
        Trace.mark("presence.transition", "\(old.isAway ? "away" : "here") -> \(new.isAway ? "away" : "here")\(silent ? " (silent)" : "")")
        if !silent { onChange?(old, new) }
    }

    // MARK: - The poll backstop

    private func armBackstop() {
        guard case .away(let since, _) = presence else { return }
        // The mouse monitor handles most returns instantly; this poll covers
        // keyboard-only returns and lock/sleep exits. Fast for the first ten
        // minutes, then relaxed: nobody is at the machine to notice.
        let awayFor = Date().timeIntervalSince(since)
        arm(after: awayFor < 600 ? 2 : 10, leeway: .milliseconds(500))
    }

    private func armThresholdWatch(idleSeconds: TimeInterval) {
        arm(after: max(1, threshold - idleSeconds), leeway: .seconds(5))
    }

    private func arm(after delay: TimeInterval, leeway: DispatchTimeInterval) {
        armedFor = (ProcessInfo.processInfo.systemUptime, delay)
        // Wall clock: a deadline-based timer does not advance through sleep.
        if let timer {
            timer.schedule(wallDeadline: .now() + delay, leeway: leeway)
        } else {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(wallDeadline: .now() + delay, leeway: leeway)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if Trace.enabled, let a = self.armedFor {
                    let late = ProcessInfo.processInfo.systemUptime - a.at - a.delay
                    Trace.mark("presence.poll", String(format: "armed=%.0fs late=%+.2fs", a.delay, late))
                }
                self.check()
            }
            t.resume()
            timer = t
        }
    }
}
