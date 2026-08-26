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
    private var ambientGlow: AmbientGlowController!
    private var reminders: MicroReminders!

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = BreakEngine()
        overlay = OverlayController(engine: engine)
        warningPill = WarningPillController(engine: engine)
        ambientGlow = AmbientGlowController()
        engine.overlayController = overlay
        engine.warningPill = warningPill
        engine.ambientGlow = ambientGlow
        reminders = MicroReminders()
        reminders.isSuppressed = { [weak engine] in
            !(engine?.allowsMicroReminders ?? false)
        }
        engine.microReminders = reminders
        menuBar = MenuBarController(engine: engine)
        IntentBridge.engine = engine
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:with:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        engine.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// halftone://break | skip | pause[?minutes=N] | resume
    @objc private func handleURL(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw), url.scheme == "halftone" else { return }
        switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "break": engine.startBreakNow()
        case "skip": engine.skipBreak()
        case "pause":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let mins = comps?.queryItems?.first(where: { $0.name == "minutes" })?.value.flatMap(Int.init) ?? 0
            engine.pause(for: mins > 0 ? TimeInterval(mins * 60) : nil)
        case "resume": engine.resume()
        default: break
        }
    }
}

@MainActor
func runProbe() {
    let seconds = Double(CommandLine.arguments.last ?? "30") ?? 30
    let engine = ContextEngine()
    let presence = PresenceMonitor()
    presence.start()

    func flagList() -> String {
        engine.activeFlags.map(\.rawValue).sorted().joined(separator: ",")
    }

    print("probing for \(Int(seconds))s — flags print on every change")
    engine.onChange = {
        print("[\(Date().formatted(date: .omitted, time: .standard))] flags=[\(flagList())] hold=\(engine.shouldHold)")
    }

    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 2, repeating: 5)
    t.setEventHandler {
        let mic = AudioProcessMonitor.shared.micPIDs
        let out = AudioProcessMonitor.shared.outputPIDs
        print("[tick] flags=[\(flagList())] hold=\(engine.shouldHold) micPIDs=\(mic) outPIDs=\(out) idleSec=\(Int(PresenceMonitor.secondsSinceLastInput())) presence=\(presence.presence.isAway ? "away" : "here")")
    }
    t.resume()

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    RunLoop.main.run()
}

@MainActor
func runShowcase(_ what: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let engine = BreakEngine()
    let overlay = OverlayController(engine: engine)
    let pill = WarningPillController(engine: engine)
    let glow = AmbientGlowController()
    let reminders = MicroReminders()
    switch what {
    case "overlay":
        overlay.show(kind: .short, endsAt: Date().addingTimeInterval(20))
    case "pill":
        pill.show(breakAt: Date().addingTimeInterval(30))
    case "glow":
        glow.show(breakAt: Date().addingTimeInterval(10)) // 10s ramp for review
    case "blink":
        reminders.fire(.blink)
    case "posture":
        reminders.fire(.posture)
    default:
        print("unknown showcase: \(what)"); exit(1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
    app.run()
}

@MainActor
public func halftoneMain() {
        // `halftone --probe` prints live detector state for N seconds. Used to
        // verify detection against real Zoom/YouTube/etc. without GUI digging.
        if CommandLine.arguments.contains("--probe") {
            runProbe()
            return
        }
        // --showcase [pill|overlay]: show that UI immediately for N seconds.
        // Exists so screenshots/tests don't have to race the real scheduler.
        if let idx = CommandLine.arguments.firstIndex(of: "--showcase"),
           idx + 1 < CommandLine.arguments.count {
            runShowcase(CommandLine.arguments[idx + 1])
            return
        }

        // Single-instance guard. The LaunchServices scan was check-then-act:
        // after a reboot, the login item and window-restore can both launch
        // within LaunchServices' registration lag, both see zero others, and
        // two instances then fight over one status-item slot and shared
        // defaults (field bug: the visible icon belonged to a desynced twin).
        // An O_EXCL lock file is atomic; a stale lock (dead PID) is taken over.
        if !SingleInstanceLock.acquire() {
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // belt-and-braces alongside LSUIElement
        app.run()
    }
