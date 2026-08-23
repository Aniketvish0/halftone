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
    private var occlusionObserver: NSObjectProtocol?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        guard let window else { return }
        // A width measured while the status window was occluded (display
        // asleep, fullscreen app) can be stale; the change-guard would then
        // pin the item at the wrong length until something forced layout,
        // which is why clicking the icon "fixed" it. Re-measure on visible.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.lastWidth = 0
                self.needsLayout = true
            }
        }
    }
}

/// The menu-bar label. Countdown text is rendered BY THE SYSTEM
/// (Text(timerInterval:)) — the app is asleep while it ticks.
struct MenuBarLabel: View {
    let engine: BreakEngine

    /// States whose label can change with time (a countdown is showing).
    private var needsClock: Bool {
        guard Preferences.shared.showCountdownInMenuBar else { return false }
        switch engine.state {
        case .working, .warning, .inBreak: return true
        default: return false
        }
    }

    var body: some View {
        // A countdown label re-derives each minute (and on every @Observable
        // change), so a reading taken at a bad moment can never stick. States
        // with no countdown skip the timeline entirely: no scheduled wakeups
        // overnight in offHours/idle or with the countdown pref off.
        if needsClock {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                // context.date is the last tick, up to ~59s old on an
                // @Observable-triggered re-render. Use the fresher of tick
                // time and now so short warnings still get their ticker.
                label(now: max(context.date, Date()))
            }
        } else {
            label(now: Date())
        }
    }

    private func label(now: Date) -> some View {
        let display = MenuBarDisplay.compute(
            state: engine.state,
            shouldHold: engine.context.shouldHold,
            holdReasons: engine.context.holdReasons,
            showCountdown: Preferences.shared.showCountdownInMenuBar,
            now: now)

        return HStack(spacing: 3) {
            Image(systemName: display.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))

            switch display.countdown {
            case .none:
                EmptyView()
            case .minutes(let m):
                Text("\(m)m")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            case .ticker(let end):
                Text(timerInterval: now...max(end, now),
                     countsDown: true, showsHours: false)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
        }
        .padding(.horizontal, 2)
        .frame(maxHeight: .infinity)
    }
}
