import AppKit
import SwiftUI

/// Programmatic AppKit lifecycle: LSUIElement agent, no SwiftUI App scene.
/// Everything hangs off the delegate; the engine drives UI controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: BreakEngine!
    private var menuBar: MenuBarController!
    private var overlay: OverlayController!
    private var warningPill: WarningPillController!
    private var stateObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = BreakEngine()
        overlay = OverlayController(engine: engine)
        warningPill = WarningPillController(engine: engine)
        engine.overlayController = overlay
        engine.warningPill = warningPill
        menuBar = MenuBarController(engine: engine)
        engine.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

@MainActor
func runProbe() {
    let seconds = Double(CommandLine.arguments.last ?? "30") ?? 30
    let engine = ContextEngine()
    let idle = IdleMonitor()
    idle.start()

    print("probing for \(Int(seconds))s — flags print on every change")
    engine.onChange = {
        let flags = engine.activeFlags.map(\.rawValue).sorted().joined(separator: ",")
        print("[\(Date().formatted(date: .omitted, time: .standard))] flags=[\(flags)] hold=\(engine.shouldHold)")
    }

    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 2, repeating: 5)
    t.setEventHandler {
        let flags = engine.activeFlags.map(\.rawValue).sorted().joined(separator: ",")
        let mic = AudioProcessMonitor.shared.micPIDs
        let out = AudioProcessMonitor.shared.outputPIDs
        print("[tick] flags=[\(flags)] hold=\(engine.shouldHold) micPIDs=\(mic) outPIDs=\(out) idleSec=\(Int(IdleMonitor.secondsSinceLastInput()))")
    }
    t.resume()

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    RunLoop.main.run()
}

@main
enum HalftoneMain {
    @MainActor
    static func main() {
        // `halftone --probe` prints live detector state for N seconds. Used to
        // verify detection against real Zoom/YouTube/etc. without GUI digging.
        if CommandLine.arguments.contains("--probe") {
            runProbe()
            return
        }

        // Single-instance guard: if another Halftone is already running, yield to it.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "me.aniket.halftone"
        ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // belt-and-braces alongside LSUIElement
        app.run()
    }
}
