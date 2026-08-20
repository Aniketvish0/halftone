import AppKit
import SwiftUI
import ServiceManagement

/// Settings in a plain window (we run without a SwiftUI App scene).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "Halftone Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @State private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Short breaks") {
                Stepper("Every \(prefs.shortIntervalMin) minutes",
                        value: $prefs.shortIntervalMin, in: 5...120, step: 5)
                Stepper("For \(prefs.shortDurationSec) seconds",
                        value: $prefs.shortDurationSec, in: 10...120, step: 5)
            }

            Section("Long breaks") {
                Stepper("Every \(prefs.longIntervalMin) minutes",
                        value: $prefs.longIntervalMin, in: 30...240, step: 10)
                Stepper("For \(prefs.longDurationSec / 60) min \(prefs.longDurationSec % 60) sec",
                        value: $prefs.longDurationSec, in: 60...1800, step: 60)
            }

            Section("Behavior") {
                Stepper("Warn \(prefs.warnLeadSec) seconds before",
                        value: $prefs.warnLeadSec, in: 0...120, step: 5)
                Toggle("Play sounds", isOn: $prefs.playSounds)
                Toggle("Show countdown in menu bar", isOn: $prefs.showCountdownInMenuBar)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
    }
}
