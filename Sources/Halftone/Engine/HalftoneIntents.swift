import AppIntents
import Foundation

/// The running engine, reachable from intents. Set by the app at launch.
@MainActor
enum IntentBridge {
    static weak var engine: BreakEngine?
}

struct StartBreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Break"
    static let description = IntentDescription("Start a break right now.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.engine?.startBreakNow()
        return .result()
    }
}

struct SkipBreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Break"
    static let description = IntentDescription("Skip the current break.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.engine?.skipBreak()
        return .result()
    }
}

struct PauseBreaksIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Breaks"
    static let description = IntentDescription("Pause break reminders, optionally for a duration.")
    static let openAppWhenRun = false

    @Parameter(title: "Minutes (0 = until resumed)", default: 0)
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.engine?.pause(for: minutes > 0 ? TimeInterval(minutes * 60) : nil)
        return .result()
    }
}

struct ResumeBreaksIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Breaks"
    static let description = IntentDescription("Resume break reminders.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.engine?.resume()
        return .result()
    }
}

struct BreakStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Break Status"
    static let description = IntentDescription("Current state and minutes until the next break.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let engine = IntentBridge.engine else {
            return .result(value: "not running")
        }
        let status: String
        switch engine.state {
        case .working(let due, _):
            status = "working, break in \(MenuBarDisplay.minutesRemaining(until: due)) min"
        case .warning: status = "break imminent"
        case .inBreak(_, let endsAt):
            status = "on break, \(max(0, Int(endsAt.timeIntervalSinceNow))) s left"
        case .pausedByUser: status = "paused"
        case .heldByContext: status = "held: \(engine.context.holdReasonsSummary)"
        case .idle: status = "away"
        case .offHours: status = "outside office hours"
        }
        return .result(value: status)
    }
}

struct HalftoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartBreakIntent(),
                    phrases: ["Start a break in \(.applicationName)"],
                    shortTitle: "Start Break", systemImageName: "eye")
        AppShortcut(intent: PauseBreaksIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause", systemImageName: "pause.circle")
    }
}
