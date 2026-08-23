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
        print("[tick] flags=[\(flagList())] hold=\(engine.shouldHold) micPIDs=\(mic) outPIDs=\(out) idleSec=\(Int(IdleMonitor.secondsSinceLastInput()))")
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

/// In-process engine tests that need the real Preferences notification path.
/// Async steps run on the main run loop; exits nonzero on failure.
@MainActor
func runSelfTest() {
    var failures = 0
    func check(_ cond: Bool, _ label: String) {
        print("\(cond ? "PASS" : "FAIL"): \(label)")
        if !cond { failures += 1 }
    }

    let prefs = Preferences.shared
    prefs.shortIntervalMin = 20
    prefs.warnLeadSec = 30
    Defaults.store.removeObject(forKey: "engineSnapshot")

    let engine = BreakEngine()
    engine.start()

    func workingDue() -> Date? {
        if case .working(let d, _) = engine.state { return d }
        return nil
    }
    // Preference posts coalesce to the next runloop turn; drain it so the
    // engine has observed the change before we assert.
    func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    guard let due0 = workingDue() else {
        print("FAIL: engine not working after start"); exit(1)
    }

    // 1. Unrelated pref change must not move the due date.
    prefs.playSounds.toggle()
    prefs.playSounds.toggle()
    drainRunLoop()
    check(abs((workingDue() ?? .distantPast).timeIntervalSince(due0)) < 1,
          "unrelated pref keeps due date")

    // 2. Interval change must re-derive from cycle start (+5 min, not +25).
    prefs.shortIntervalMin = 25
    drainRunLoop()
    let delta = (workingDue() ?? .distantPast).timeIntervalSince(due0)
    check(abs(delta - 300) < 2, "interval 20->25 moves due by +300s (was \(Int(delta))s)")
    prefs.shortIntervalMin = 20
    drainRunLoop()

    // 3. Pause/resume keeps remaining time.
    engine.pause()
    engine.resume()
    check(abs((workingDue() ?? .distantPast).timeIntervalSince(due0)) < 3,
          "pause/resume keeps remaining")

    // 4. Take Break Now must enter a break; skip returns to working.
    engine.startBreakNow()
    var inBreak = false
    if case .inBreak = engine.state { inBreak = true }
    check(inBreak, "startBreakNow enters break")
    engine.skipBreak()
    check(workingDue() != nil, "skip returns to working")

    exit(failures == 0 ? 0 : 1)
}

/// Entry point, called by the executable target's @main.
@MainActor
public func halftoneMain() {
        // `halftone --probe` prints live detector state for N seconds. Used to
        // verify detection against real Zoom/YouTube/etc. without GUI digging.
        if CommandLine.arguments.contains("--probe") {
            runProbe()
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
            return
        }
        // --showcase [pill|overlay]: show that UI immediately for N seconds.
        // Exists so screenshots/tests don't have to race the real scheduler.
        if let idx = CommandLine.arguments.firstIndex(of: "--showcase"),
           idx + 1 < CommandLine.arguments.count {
            runShowcase(CommandLine.arguments[idx + 1])
            return
        }

        // Single-instance guard: if another Halftone is already running, yield to it.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: "me.aniket.halftone"
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
