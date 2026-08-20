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

@main
enum HalftoneMain {
    @MainActor
    static func main() {
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
