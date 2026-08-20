import AppKit
import SwiftUI

/// Hybrid menu-bar item: NSStatusItem + NSHostingView label (so we get the
/// system-rendered zero-CPU countdown) + a plain NSMenu for controls.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let engine: BreakEngine
    private var hostingView: NSHostingView<MenuBarLabel>?

    init(engine: BreakEngine) {
        self.engine = engine
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let label = MenuBarLabel(engine: engine)
        let hosting = NSHostingView(rootView: label)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let button = statusItem.button {
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        hostingView = hosting

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild menu each open so labels reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

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

/// The menu-bar label. Countdown text is rendered BY THE SYSTEM
/// (Text(timerInterval:)) — the app is asleep while it ticks.
struct MenuBarLabel: View {
    let engine: BreakEngine

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)

            if Preferences.shared.showCountdownInMenuBar, let range = countdownRange {
                Text(timerInterval: range, countsDown: true, showsHours: false)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var symbolName: String {
        switch engine.state {
        case .working: "circle.lefthalf.filled"
        case .warning: "circle.lefthalf.filled.inverse"
        case .inBreak: "eye"
        case .pausedByUser: "pause.circle"
        }
    }

    private var countdownRange: ClosedRange<Date>? {
        let now = Date()
        switch engine.state {
        case .working(let due, _), .warning(let due, _):
            return due > now ? now...due : nil
        case .inBreak(_, let endsAt):
            return endsAt > now ? now...endsAt : nil
        case .pausedByUser:
            return nil
        }
    }
}
