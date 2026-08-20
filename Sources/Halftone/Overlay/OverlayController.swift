import AppKit
import SwiftUI

/// Owns one OverlayPanel per screen. Handles show/hide with alpha fades and
/// screen-configuration changes (debounced — the notification is noisy).
@MainActor
final class OverlayController {
    private var panels: [OverlayPanel] = []
    private let rebuildDebounce = Debouncer(delay: 0.5)
    private weak var engine: BreakEngine?
    private var visible = false
    private var currentKind: BreakKind = .short
    private var currentEndsAt = Date()

    init(engine: BreakEngine) {
        self.engine = engine
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func show(kind: BreakKind, endsAt: Date) {
        currentKind = kind
        currentEndsAt = endsAt
        buildPanels()
        visible = true
        for panel in panels {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // Key window on the main-screen panel so Esc/skip shortcuts can work later.
        panels.first?.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for panel in panels { panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        let closing = panels
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            for panel in closing { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            // MUST order out: an invisible window still eats clicks.
            // Also destroy content — a live NSHostingView in an ordered-out
            // window keeps TimelineView animations rendering (CPU leak).
            for panel in closing {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
        panels = []
    }

    private func buildPanels() {
        for panel in panels { panel.orderOut(nil); panel.contentView = nil }
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(
                screen: screen,
                content: AnyView(
                    BreakOverlayView(
                        kind: currentKind,
                        endsAt: currentEndsAt,
                        onSkip: { [weak self] in self?.engine?.skipBreak() },
                        onSnooze: { [weak self] in self?.engine?.snooze() }
                    )
                )
            )
            panel.onEscape = { [weak self] in self?.engine?.skipBreak() }
            return panel
        }
    }

    private func screensChanged() {
        rebuildDebounce.schedule { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visible else { return }
                self.buildPanels()
                for panel in self.panels {
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
            }
        }
    }
}
