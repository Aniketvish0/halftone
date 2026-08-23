import Foundation

/// The menu bar label, as a pure decision: (engine state, hold state, prefs,
/// clock) -> (symbol, countdown form). Extracted from the view so every edge
/// case is unit-testable, and evaluated inside a per-minute TimelineView so a
/// transiently-invalid reading self-heals on the next tick instead of
/// sticking until something else happens to re-render the view.
struct MenuBarDisplay: Equatable {
    enum Countdown: Equatable {
        case none
        /// "Nm" static label, re-derived each minute.
        case minutes(Int)
        /// System-rendered live ticker until this date (final minute).
        case ticker(until: Date)
    }

    var symbol: String
    var countdown: Countdown

    static func compute(state: BreakEngine.State,
                        shouldHold: Bool,
                        holdReasons: Set<ContextFlag>,
                        showCountdown: Bool,
                        now: Date) -> MenuBarDisplay {
        let holdSymbol = holdReasons.min(by: { $0.priority < $1.priority })?.symbolName
            ?? "circle.lefthalf.filled"

        let symbol: String
        switch state {
        case .working, .warning:
            symbol = shouldHold ? holdSymbol : "circle.lefthalf.filled"
        case .inBreak: symbol = "eye"
        case .pausedByUser: symbol = "pause.circle"
        case .heldByContext: symbol = holdSymbol
        case .idle: symbol = "moon.zzz"
        case .offHours: symbol = "sunset"
        }

        guard showCountdown else { return .init(symbol: symbol, countdown: .none) }

        let end: Date?
        switch state {
        case .working(let due, _), .warning(let due, _): end = due
        case .inBreak(_, let endsAt): end = endsAt
        default: end = nil
        }
        guard let end, end > now else {
            // Past-due reading (timer leeway, wake race): show icon only NOW,
            // but the per-minute re-evaluation recovers as soon as the engine
            // advances - the old code could stick like this until a click.
            return .init(symbol: symbol, countdown: .none)
        }

        let remaining = end.timeIntervalSince(now)
        if remaining > 60 {
            return .init(symbol: symbol, countdown: .minutes(Int((remaining / 60).rounded(.up))))
        }
        return .init(symbol: symbol, countdown: .ticker(until: end))
    }
}
