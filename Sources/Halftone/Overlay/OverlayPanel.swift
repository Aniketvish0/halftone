import AppKit
import SwiftUI

/// Borderless, non-activating panel that covers one screen, joins all Spaces,
/// and floats above fullscreen apps. The canonical break-overlay window.
/// (Pattern verified against jordanbaird/Ice's MenuBarOverlayPanel.)
final class OverlayPanel: NSPanel {
    /// Set on blocking break panels: Escape triggers this instead of NSPanel's
    /// default cancel behavior (which closes the window without telling the
    /// engine, leaving state and UI disagreeing).
    var onEscape: (() -> Void)?

    /// Passive panels (glow, reminders) refuse key status so the hosting view
    /// never draws a focus ring.
    var refusesKey = false

    init(screen: NSScreen, content: AnyView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: content.ignoresSafeArea())
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { !refusesKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}


extension OverlayPanel {
    /// Fades out and tears down. Both halves are load-bearing: an ordered-in
    /// but invisible window still eats clicks, and a live NSHostingView keeps
    /// rendering its animations even when ordered out (CPU leak).
    static func dismiss(_ panels: [OverlayPanel], duration: TimeInterval) {
        guard !panels.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            for p in panels { p.animator().alphaValue = 0 }
        }, completionHandler: {
            for p in panels { p.orderOut(nil); p.contentView = nil }
        })
    }

    /// Shared setup for passive (non-interactive) panels: glow, reminders.
    func makePassive(level: NSWindow.Level) {
        self.level = level
        ignoresMouseEvents = true
        refusesKey = true
        hasShadow = false
    }
}
