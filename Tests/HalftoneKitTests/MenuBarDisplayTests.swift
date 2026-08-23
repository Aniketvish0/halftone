import Testing
import Foundation
import AppKit
@testable import HalftoneKit

/// Every menu-bar label edge case, as pure-function tests over
/// MenuBarDisplay.compute. No shared state; safe to run in parallel.
@MainActor
struct MenuBarDisplayTests {

    let now = Date()
    func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    func compute(_ state: BreakEngine.State,
                 hold: Bool = false,
                 reasons: Set<ContextFlag> = [],
                 show: Bool = true) -> MenuBarDisplay {
        MenuBarDisplay.compute(state: state, shouldHold: hold,
                               holdReasons: reasons, showCountdown: show, now: now)
    }

    // MARK: Countdown forms

    @Test func workingFarOutShowsMinutes() {
        let d = compute(.working(nextBreakAt: at(19 * 60 + 30), kind: .short))
        #expect(d.symbol == "circle.lefthalf.filled")
        #expect(d.countdown == .minutes(20), "19.5 min remaining rounds up to 20m")
    }

    @Test func exactMinuteBoundaryRoundsCleanly() {
        let d = compute(.working(nextBreakAt: at(120), kind: .short))
        #expect(d.countdown == .minutes(2), "exactly 120s is 2m, not 3m")
    }

    @Test func finalMinuteSwitchesToTicker() {
        let end = at(59)
        let d = compute(.working(nextBreakAt: end, kind: .short))
        #expect(d.countdown == .ticker(until: end))
    }

    @Test func sixtyOneSecondsIsStillMinutes() {
        let d = compute(.working(nextBreakAt: at(61), kind: .short))
        #expect(d.countdown == .minutes(2), "61s rounds up to 2m; ticker only under 60s")
    }

    /// THE FIELD BUG: a due date in the past must yield icon-only, never a
    /// crash or a stuck stale number — and (covered by the TimelineView) it
    /// re-evaluates within a minute.
    @Test func pastDueShowsIconOnly() {
        let d = compute(.working(nextBreakAt: at(-5), kind: .short))
        #expect(d.countdown == .none)
        #expect(d.symbol == "circle.lefthalf.filled")
    }

    @Test func dueExactlyNowShowsIconOnly() {
        let d = compute(.working(nextBreakAt: now, kind: .short))
        #expect(d.countdown == .none, "end > now is strict; equal is past")
    }

    @Test func breakCountdownTicksToBreakEnd() {
        let end = at(15)
        let d = compute(.inBreak(kind: .short, endsAt: end))
        #expect(d.symbol == "eye")
        #expect(d.countdown == .ticker(until: end))
    }

    @Test func warningUsesItsBreakDate() {
        let end = at(25)
        let d = compute(.warning(breakAt: end, kind: .short))
        #expect(d.countdown == .ticker(until: end))
    }

    // MARK: Preference gate

    @Test func hiddenCountdownIsIconOnlyInEveryState() {
        for state: BreakEngine.State in [
            .working(nextBreakAt: at(600), kind: .short),
            .warning(breakAt: at(20), kind: .short),
            .inBreak(kind: .short, endsAt: at(15)),
        ] {
            #expect(compute(state, show: false).countdown == .none)
        }
    }

    // MARK: States without countdowns

    @Test func stateOnlyIconsShowNoCountdown() {
        #expect(compute(.pausedByUser(until: at(3600))).countdown == .none)
        #expect(compute(.pausedByUser(until: nil)).countdown == .none)
        #expect(compute(.heldByContext(kind: .short, overdueSince: now)).countdown == .none)
        #expect(compute(.idle(since: now, pending: nil)).countdown == .none)
        #expect(compute(.offHours).countdown == .none)
    }

    @Test func stateSymbols() {
        #expect(compute(.pausedByUser(until: nil)).symbol == "pause.circle")
        #expect(compute(.idle(since: now, pending: nil)).symbol == "moon.zzz")
        #expect(compute(.offHours).symbol == "sunset")
        #expect(compute(.inBreak(kind: .short, endsAt: at(10))).symbol == "eye")
    }

    // MARK: Hold icon selection

    @Test func holdDuringCountdownShowsReasonIcon() {
        let d = compute(.working(nextBreakAt: at(600), kind: .short),
                        hold: true, reasons: [.mediaPlaying])
        #expect(d.symbol == "play.rectangle")
        #expect(d.countdown == .minutes(10), "countdown keeps ticking during a hold")
    }

    @Test func callBeatsEveryOtherReason() {
        let d = compute(.heldByContext(kind: .short, overdueSince: now),
                        reasons: [.fullscreenApp, .mediaPlaying, .micInUse, .screenCaptured])
        #expect(d.symbol == "person.wave.2")
    }

    @Test func priorityOrderIsTotal() {
        // Every pair: lower priority value wins.
        let flags: [ContextFlag] = [.micInUse, .screenCaptured, .cameraInUse,
                                    .mediaPlaying, .fullscreenApp, .deepFocusApp]
        for (i, a) in flags.enumerated() {
            for b in flags.dropFirst(i + 1) {
                let d = compute(.heldByContext(kind: .short, overdueSince: now),
                                reasons: [a, b])
                #expect(d.symbol == a.symbolName,
                        "\(a) must beat \(b)")
            }
        }
    }

    @Test func emptyReasonsFallsBackNeutral() {
        let d = compute(.heldByContext(kind: .short, overdueSince: now), reasons: [])
        #expect(d.symbol == "circle.lefthalf.filled",
                "unreachable in prod, but must fail neutral, not as a phantom call")
    }

    /// Every symbol the display can ever emit must be a real SF Symbol.
    @Test func allEmittableSymbolsAreValid() {
        var symbols: Set<String> = ["circle.lefthalf.filled", "eye",
                                    "pause.circle", "moon.zzz", "sunset"]
        for flag in [ContextFlag.micInUse, .cameraInUse, .screenCaptured,
                     .mediaPlaying, .fullscreenApp, .deepFocusApp] {
            symbols.insert(flag.symbolName)
        }
        for name in symbols {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(name) is not a valid SF Symbol")
        }
    }

    // MARK: Clock robustness

    @Test func absurdFutureDateStillComputes() {
        let d = compute(.working(nextBreakAt: at(86_400 * 365), kind: .short))
        #expect(d.countdown == .minutes(525_600), "a year out: huge but well-formed")
    }

    @Test func equatableSupportsChangeDetection() {
        let a = compute(.working(nextBreakAt: at(600), kind: .short))
        let b = compute(.working(nextBreakAt: at(600), kind: .short))
        #expect(a == b)
    }
}
