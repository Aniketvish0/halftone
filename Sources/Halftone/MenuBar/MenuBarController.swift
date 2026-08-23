import AppKit
import SwiftUI

/// Hybrid menu-bar item: NSStatusItem + NSHostingView label (so we get the
/// system-rendered zero-CPU countdown) + a plain NSMenu for controls.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let engine: BreakEngine

    init(engine: BreakEngine) {
        self.engine = engine

        // Crowded/notched menu bars: macOS hides lowest-priority items, and a
        // brand-new app gets the lowest priority of all. Seed a position near
        // the right edge once, so Halftone wins a visible slot; the user can
        // still Cmd-drag it anywhere (which updates this saved value).
        let posKey = "NSStatusItem Preferred Position halftone-main"
        if UserDefaults.standard.object(forKey: posKey) == nil {
            UserDefaults.standard.set(150.0, forKey: posKey)
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "halftone-main"
        super.init()

        let label = MenuBarLabel(engine: engine)
        // NSStatusBarButton won't grow from subview constraints — the item
        // length must be driven explicitly. AutoWidthHostingView reports its
        // SwiftUI fitting width after every layout pass and we sync length.
        let hosting = AutoWidthHostingView(rootView: label)
        hosting.onWidthChange = { [weak self] width in
            guard let self else { return }
            let target = ceil(width)
            if target > 1, abs(self.statusItem.length - target) > 0.5 {
                self.statusItem.length = target
            }
        }
        if let button = statusItem.button {
            let width = hosting.fittingSize.width
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: button.bounds.height)
            hosting.autoresizingMask = [.height]
            button.addSubview(hosting)
            statusItem.length = width
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild menu each open so labels reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status line (disabled item) when something non-obvious is happening.
        let statusText: String? = {
            switch engine.state {
            case .heldByContext:
                return "Holding: \(engine.context.holdReasonsSummary)"
            case .working, .warning:
                guard engine.context.shouldHold else { return nil }
                return "Will hold: \(engine.context.holdReasonsSummary)"
            case .idle: return "Away — time counts as your break"
            case .offHours: return "Outside office hours"
            case .pausedByUser(let until):
                if let until {
                    return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
                }
                return "Paused"
            default: return nil
            }
        }()
        if let statusText {
            let item = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        switch engine.state {
        case .pausedByUser:
            menu.addItem(makeItem("Resume Breaks", #selector(resumeAction), key: "r"))
        default:
            menu.addItem(makeItem("Take Break Now", #selector(breakNowAction), key: "b"))
            menu.addItem(makeItem("Pause for 1 Hour", #selector(pauseHourAction), key: ""))
            menu.addItem(makeItem("Pause Until Resumed", #selector(pauseAction), key: "p"))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(settingsAction), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Halftone", #selector(quitAction), key: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func breakNowAction() { engine.startBreakNow() }
    @objc private func pauseHourAction() { engine.pause(for: 3600) }
    @objc private func pauseAction() { engine.pause() }
    @objc private func resumeAction() { engine.resume() }
    @objc private func settingsAction() {
        NSApp.activate()
        SettingsWindowController.shared.show()
    }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// NSHostingView that reports its fitting width after each SwiftUI layout,
/// letting the owner keep NSStatusItem.length in sync with dynamic content.
final class AutoWidthHostingView<V: View>: NSHostingView<V> {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        // fittingSize is a full SwiftUI measurement pass, and both the frame
        // write and the length callback re-dirty layout — only act on change.
        let width = fittingSize.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        frame.size.width = width
        onWidthChange?(width)
    }
}

/// The menu-bar label. Countdown text is rendered BY THE SYSTEM
/// (Text(timerInterval:)) — the app is asleep while it ticks.
struct MenuBarLabel: View {
    let engine: BreakEngine

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))

            if Preferences.shared.showCountdownInMenuBar, let range = countdownRange {
                // Energy: per-second ticking redraws our status window ~3x/s
                // (0.3-0.4% CPU). So render "18m" via a once-a-minute timeline
                // while >60s remain; the live ticker only in the final minute.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Group {
                        if range.upperBound.timeIntervalSince(context.date) > 60 {
                            Text(minutesLabel(until: range.upperBound, from: context.date))
                        } else {
                            Text(timerInterval: range, countsDown: true, showsHours: false)
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(maxHeight: .infinity)
    }

    /// Icon for the strongest active hold reason: person = call, record badge
    /// = screen share, video = camera, play = video watching, etc. Mapping
    /// every reason to the call icon made "watching YouTube" read as the app
    /// wrongly claiming a call.
    private var holdSymbol: String {
        engine.context.holdReasons.min(by: { $0.priority < $1.priority })?.symbolName
            ?? "circle.lefthalf.filled" // unreachable; fail neutral, not as a phantom call
    }

    private var symbolName: String {
        // A detected hold shows its reason icon immediately, even while the
        // countdown is still running. "I see what you're doing, the break
        // will wait" must be visible before the break is due, not only after.
        switch engine.state {
        case .working, .warning:
            engine.context.shouldHold ? holdSymbol : "circle.lefthalf.filled"
        case .inBreak: "eye"
        case .pausedByUser: "pause.circle"
        case .heldByContext: holdSymbol
        case .idle: "moon.zzz"
        case .offHours: "sunset"
        }
    }

    private func minutesLabel(until end: Date, from now: Date) -> String {
        let mins = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        return "\(mins)m"
    }

    private var countdownRange: ClosedRange<Date>? {
        let now = Date()
        switch engine.state {
        case .working(let end, _), .warning(let end, _), .inBreak(_, let end):
            return end > now ? now...end : nil
        default:
            return nil
        }
    }
}
