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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
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
    var body: some View {
        TabView {
            Tab("Breaks", systemImage: "timer") { BreaksPane() }
            Tab("Smart Pause", systemImage: "person.wave.2") { SmartPausePane() }
            Tab("Schedule", systemImage: "calendar.badge.clock") { SchedulePane() }
        }
        .frame(width: 560, height: 560)
    }
}

struct BreaksPane: View {
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
    }
}

struct SmartPausePane: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.pauseOnMic) {
                    Label { Text("On a call"); Text("Any app using the microphone — Zoom, Meet, Teams, FaceTime, huddles").font(.caption).foregroundStyle(.secondary) } icon: { Image(systemName: "mic.fill") }
                }
                Toggle(isOn: $prefs.pauseOnCamera) {
                    Label { Text("Camera in use"); Text("Any app using any camera").font(.caption).foregroundStyle(.secondary) } icon: { Image(systemName: "video.fill") }
                }
                Toggle(isOn: $prefs.pauseOnScreenCapture) {
                    Label { Text("Screen shared or recording"); Text("Zoom/Meet shares, OBS, QuickTime, screenshots apps").font(.caption).foregroundStyle(.secondary) } icon: { Image(systemName: "rectangle.badge.record") }
                }
                Toggle(isOn: $prefs.pauseOnMedia) {
                    Label { Text("Video playing"); Text("Playing audio while keeping the display awake").font(.caption).foregroundStyle(.secondary) } icon: { Image(systemName: "play.rectangle.fill") }
                }
                Toggle(isOn: $prefs.pauseOnFullscreen) {
                    Label { Text("Fullscreen apps"); Text("Games, presentations, fullscreen video").font(.caption).foregroundStyle(.secondary) } icon: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                }
            } header: {
                Text("Hold breaks while…")
            } footer: {
                Text("Held breaks fire ~15 seconds after the activity ends.")
            }

            Section("After activity ends") {
                Stepper("Keep holding for \(prefs.contextLingerSec) s",
                        value: $prefs.contextLingerSec, in: 0...300, step: 15)
            }

            Section {
                Toggle(isOn: $prefs.pauseOnDeepFocusApps) {
                    Label("Hold while these apps are frontmost", systemImage: "scope")
                }
                DeepFocusAppList()
                    .disabled(!prefs.pauseOnDeepFocusApps)
            } header: {
                Text("Focus apps")
            }
        }
        .formStyle(.grouped)
    }
}

/// Add/remove bundle IDs; "+" lists currently running regular apps.
struct DeepFocusAppList: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        ForEach(Array(prefs.deepFocusApps).sorted(), id: \.self) { bid in
            HStack {
                Text(appName(for: bid))
                Text(bid).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) {
                    prefs.deepFocusApps.remove(bid)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        Menu("Add Running App…") {
            ForEach(runningApps(), id: \.bundleIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                    if let bid = app.bundleIdentifier {
                        prefs.deepFocusApps.insert(bid)
                    }
                }
            }
        }
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      let bid = app.bundleIdentifier else { return false }
                return !prefs.deepFocusApps.contains(bid)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(for bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
              let bundle = Bundle(url: url) else { return bid }
        return bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? bid
    }
}

struct SchedulePane: View {
    @State private var prefs = Preferences.shared

    private static let dayNames = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"),
                                   (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        Form {
            Section {
                Toggle("Step away is a natural break", isOn: $prefs.idleEnabled)
                Stepper("Away after \(prefs.idleThresholdSec / 60) min \(prefs.idleThresholdSec % 60) s of no input",
                        value: $prefs.idleThresholdSec, in: 30...900, step: 30)
                    .disabled(!prefs.idleEnabled)
            } header: {
                Text("Natural breaks")
            } footer: {
                Text("Time away counts toward your break; long enough resets the cycle. Watching video doesn't count as away.")
            }

            Section("Office hours") {
                Toggle("Only remind during office hours", isOn: $prefs.officeHoursEnabled)
                Group {
                    HStack {
                        Text("From")
                        MinutePicker(minutes: $prefs.officeStartMin)
                        Text("to")
                        MinutePicker(minutes: $prefs.officeEndMin)
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.dayNames, id: \.0) { (num, name) in
                            Toggle(name, isOn: Binding(
                                get: { prefs.officeDays.contains(num) },
                                set: { on in
                                    if on { prefs.officeDays.insert(num) }
                                    else { prefs.officeDays.remove(num) }
                                }
                            ))
                            .toggleStyle(.button)
                            .controlSize(.small)
                        }
                    }
                }
                .disabled(!prefs.officeHoursEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct MinutePicker: View {
    @Binding var minutes: Int

    var body: some View {
        Picker("", selection: $minutes) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { m in
                Text(String(format: "%d:%02d", m / 60, m % 60)).tag(m)
            }
        }
        .labelsHidden()
        .frame(width: 90)
    }
}
