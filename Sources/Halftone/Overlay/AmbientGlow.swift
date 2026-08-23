import AppKit
import SwiftUI

/// The ambient pre-break signal: a soft glow creeping in from the screen
/// edges, ramping from imperceptible to unmistakable as the break approaches.
/// Pressure you feel in peripheral vision instead of a popup in your face.
///
/// Click-through (ignoresMouseEvents), below the pill/overlay levels, one
/// panel per screen. The ramp is a single N-second ease-in animation handed
/// to the render server, so the app sleeps while it breathes in.
@MainActor
final class AmbientGlowController {
    private var panels: [OverlayPanel] = []
    private var visible = false

    /// Shows the glow ramping from now until `breakAt`.
    func show(breakAt: Date) {
        hide()
        let duration = max(1, breakAt.timeIntervalSinceNow)
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(
                screen: screen,
                content: AnyView(AmbientGlowView(rampDuration: duration))
            )
            panel.level = .statusBar - 1     // under the pill, over normal windows
            panel.ignoresMouseEvents = true  // never intercepts the user
            panel.refusesKey = true          // no focus ring on the hosting view
            panel.hasShadow = false          // shadow traces the strip edges otherwise
            panel.setFrame(screen.frame, display: true)
            return panel
        }
        visible = true
        for panel in panels {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        let closing = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            for panel in closing { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for panel in closing {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }
}

/// Edge vignette that eases in over the whole ramp. One animation, zero
/// app-side ticking (same render-server rule as the break mesh).
struct AmbientGlowView: View {
    let rampDuration: TimeInterval
    @State private var ramped = false

    var body: some View {
        // Four soft edge strips (linear gradients fading to clear) instead of
        // a radial vignette: radial center/radius math fights non-square
        // screens and renders a visible ellipse ring. Edge strips hug the
        // bezel evenly and blur into the content.
        GeometryReader { geo in
            let tint = Color(red: 0.3, green: 0.25, blue: 0.75)
            let depth = min(geo.size.width, geo.size.height) * 0.16
            ZStack {
                VStack {
                    LinearGradient(colors: [tint, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: depth)
                    Spacer()
                    LinearGradient(colors: [.clear, tint], startPoint: .top, endPoint: .bottom)
                        .frame(height: depth)
                }
                HStack {
                    LinearGradient(colors: [tint, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: depth)
                    Spacer()
                    LinearGradient(colors: [.clear, tint], startPoint: .leading, endPoint: .trailing)
                        .frame(width: depth)
                }
            }
            .opacity(ramped ? 0.5 : 0.0)
            .animation(.easeIn(duration: rampDuration), value: ramped)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear { ramped = true }
    }
}
