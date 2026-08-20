import AppKit
import SwiftUI

/// Borderless, non-activating panel that covers one screen, joins all Spaces,
/// and floats above fullscreen apps. The canonical break-overlay window.
/// (Pattern verified against jordanbaird/Ice's MenuBarOverlayPanel.)
final class OverlayPanel: NSPanel {
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
