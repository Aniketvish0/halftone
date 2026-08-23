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
    private var blinkTimer: DispatchSourceTimer?
    private var postureTimer: DispatchSourceTimer?
    private var flashPanel: OverlayPanel?

    /// The engine gates when reminders may appear.
    var isSuppressed: (() -> Bool)?

    init() {
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyToggles() }
        }
        applyToggles()
    }

    private func applyToggles() {
        blinkTimer = retime(blinkTimer, enabled: prefs.blinkEnabled,
                            minutes: prefs.blinkIntervalMin) { [weak self] in
            self?.fire(.blink)
        }
        postureTimer = retime(postureTimer, enabled: prefs.postureEnabled,
                              minutes: prefs.postureIntervalMin) { [weak self] in
            self?.fire(.posture)
        }
    }

    private func retime(_ timer: DispatchSourceTimer?, enabled: Bool,
                        minutes: Int, _ block: @escaping () -> Void) -> DispatchSourceTimer? {
        timer?.cancel()
        guard enabled else { return nil }
        let interval = TimeInterval(max(1, minutes) * 60)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(30))
        t.setEventHandler(handler: block)
        t.resume()
        return t
    }

    func fire(_ kind: Kind) {
        guard !(isSuppressed?() ?? false), flashPanel == nil,
              let screen = NSScreen.main else { return }
        let panel = OverlayPanel(screen: screen, content: AnyView(MicroReminderView(kind: kind)))
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.refusesKey = true
        panel.hasShadow = false
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
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                p.contentView = nil
            })
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
