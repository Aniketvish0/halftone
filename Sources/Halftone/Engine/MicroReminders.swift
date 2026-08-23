import AppKit
import SwiftUI

/// Blink and posture micro-reminders: a 3-second soft flash at the top edge
/// with a glyph and a word. Independent cadence from breaks; suppressed while
/// anything else is on screen (break, warning, hold) or the user is away.
@MainActor
final class MicroReminders {
    enum Kind {
        case blink, posture
        var symbol: String { self == .blink ? "eye" : "figure.stand" }
        var text: String { self == .blink ? "Blink" : "Sit tall" }
    }

    private let prefs = Preferences.shared
    private let blink = RepeatingPoller()
    private let posture = RepeatingPoller()
    private var flashPanel: OverlayPanel?
    private var applied: (blink: Bool, blinkMin: Int, posture: Bool, postureMin: Int)?

    /// The engine gates when reminders may appear.
    var isSuppressed: (() -> Bool)?

    /// The engine reports whether reminders should run at all (plain working
    /// time). Timers stop entirely outside it: no overnight wakes in
    /// offHours/idle, and no fires silently dropped by the suppression check.
    private(set) var active = false

    init() {
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyToggles(force: false) }
        }
    }

    /// Engine calls this on every state settle.
    func setActive(_ nowActive: Bool) {
        guard nowActive != active else { return }
        active = nowActive
        applyToggles(force: true)
    }

    private func applyToggles(force: Bool) {
        // Every Preferences.changed post lands here; without the guard, an
        // unrelated Settings tweak restarts both cadences from zero.
        let now = (prefs.blinkEnabled, prefs.blinkIntervalMin,
                   prefs.postureEnabled, prefs.postureIntervalMin)
        guard force || applied == nil || applied! != now else { return }
        applied = now
        schedule(blink, enabled: active && now.0, minutes: now.1) { [weak self] in self?.fire(.blink) }
        schedule(posture, enabled: active && now.2, minutes: now.3) { [weak self] in self?.fire(.posture) }
    }

    private func schedule(_ poller: RepeatingPoller, enabled: Bool, minutes: Int,
                          _ block: @escaping () -> Void) {
        poller.stop()
        guard enabled else { return }
        poller.start(interval: TimeInterval(max(1, minutes) * 60),
                     leeway: .seconds(30), block)
    }

    func fire(_ kind: Kind) {
        guard !(isSuppressed?() ?? false), flashPanel == nil,
              let screen = NSScreen.main else { return }
        let panel = OverlayPanel(screen: screen, content: AnyView(MicroReminderView(kind: kind)))
        panel.makePassive(level: .statusBar)
        let size = NSSize(width: 200, height: 56)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - size.height - 44,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        flashPanel = panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, let p = self.flashPanel else { return }
            self.flashPanel = nil
            OverlayPanel.dismiss([p], duration: 0.5)
        }
    }
}

struct MicroReminderView: View {
    let kind: MicroReminders.Kind

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 15, weight: .semibold))
                Text(kind.text)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
