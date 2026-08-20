import AppKit
import SwiftUI

/// The pre-break heads-up: a small glass pill near the top of the main screen
/// with a live countdown. Click-through is OFF (you can press Snooze),
/// but it never steals focus (non-activating panel at status level).
@MainActor
final class WarningPillController {
    private var panel: OverlayPanel?
    private weak var engine: BreakEngine?

    init(engine: BreakEngine) {
        self.engine = engine
    }

    func show(breakAt: Date) {
        hide()
        guard let screen = NSScreen.main else { return }
        let content = AnyView(
            WarningPillView(
                breakAt: breakAt,
                onSnooze: { [weak self] in self?.engine?.snooze() }
            )
        )
        let p = OverlayPanel(screen: screen, content: content)
        p.level = .statusBar
        p.backgroundColor = .clear
        // Size the pill: centered horizontally, near the top.
        let size = NSSize(width: 320, height: 64)
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height - 44
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            p.contentView = nil
        })
    }
}

struct WarningPillView: View {
    let breakAt: Date
    let onSnooze: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 15, weight: .semibold))

                Text("Break in")
                    .font(.system(size: 13, weight: .medium))

                Text(timerInterval: Date()...max(breakAt, Date()), countsDown: true, showsHours: false)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())

                Button("Snooze", action: onSnooze)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
