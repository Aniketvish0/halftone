import AppKit
import SwiftUI

/// Hybrid menu-bar item: NSStatusItem + NSHostingView label (so we get the
/// system-rendered zero-CPU countdown) + a plain NSMenu for controls.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let engine: BreakEngine
    private var hostingView: AutoWidthHostingView<MenuBarLabel>?

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
            hosting.frame = NSRect(x: 0, y: 0, width: hosting.fittingSize.width,
                                   height: button.bounds.height)
            hosting.autoresizingMask = [.height]
            button.addSubview(hosting)
            statusItem.length = hosting.fittingSize.width
        }
        hostingView = hosting

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
                let reasons = engine.context.holdReasons.map(\.displayName).sorted().joined(separator: ", ")
                return "Holding: \(reasons.isEmpty ? "recent activity" : reasons)"
            case .idle: return "Away — time counts as your break"
            case .offHours: return "Outside office hours"
            case .pausedByUser(let until):
                if let until {
                    let f = DateFormatter(); f.timeStyle = .short
                    return "Paused until \(f.string(from: until))"
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

    override func layout() {
        super.layout()
        let width = fittingSize.width
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
                .overlay(alignment: .topTrailing) {
                    // Live "I see your call" indicator: a small dot whenever a
                    // hold condition is detected, even mid-countdown, so a
                    // ticking timer during a meeting reads as safe, not armed.
                    if engine.context.shouldHold, showsDot {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -1)
                    }
                }

            if Preferences.shared.showCountdownInMenuBar, let range = countdownRange {
                // Energy: per-second ticking redraws our status window ~3x/s
                // (0.3-0.4% CPU). So render "18m" via a once-a-minute timeline
                // while >60s remain; the live ticker only in the final minute.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if range.upperBound.timeIntervalSince(context.date) > 60 {
                        Text(minutesLabel(until: range.upperBound, from: context.date))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    } else {
                        Text(timerInterval: range, countsDown: true, showsHours: false)
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(maxHeight: .infinity)
    }

    /// The dot is redundant when the icon itself already means "held".
    private var showsDot: Bool {
        switch engine.state {
        case .working, .warning: true
        default: false
        }
    }

    private var symbolName: String {
        switch engine.state {
        case .working: "circle.lefthalf.filled"
        case .warning: "circle.lefthalf.filled.inverse"
        case .inBreak: "eye"
        case .pausedByUser: "pause.circle"
        case .heldByContext: "person.wave.2"   // in a meeting / engaged
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
        case .working(let due, _), .warning(let due, _):
            return due > now ? now...due : nil
        case .inBreak(_, let endsAt):
            return endsAt > now ? now...endsAt : nil
        case .pausedByUser, .heldByContext, .idle, .offHours:
            return nil
        }
    }
}
