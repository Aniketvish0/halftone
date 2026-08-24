import Foundation

/// User-scriptable event hooks: for each engine event, if an executable
/// exists at ~/.config/halftone/hooks/<event>, run it with context in env
/// vars. Fire-and-forget, detached, never blocks the engine.
///
/// Events: break-warning, break-start, break-end, break-skipped, hold-start,
/// hold-end, idle-start, idle-end, reminder-blink, reminder-posture.
@MainActor
final class EventHooks {
    static let shared = EventHooks()

    private let hooksDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/halftone/hooks")

    func fire(_ event: String, context: [String: String] = [:]) {
        let script = hooksDir.appendingPathComponent(event)
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return }
        let proc = Process()
        proc.executableURL = script
        var env = ProcessInfo.processInfo.environment
        env["HALFTONE_EVENT"] = event
        for (k, v) in context { env["HALFTONE_\(k.uppercased())"] = v }
        proc.environment = env
        // Detached: a hanging user script must never affect the engine.
        try? proc.run()
    }
}
