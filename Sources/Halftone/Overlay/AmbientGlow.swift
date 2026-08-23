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
    private var currentTarget: Date?
    private let rebuildDebounce = Debouncer(delay: 0.5)

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildDebounce.schedule { [weak self] in
                    MainActor.assumeIsolated {
                        // Rebuild for the same target: displays changed, so
                        // bypass the idempotence guard via hide-then-show.
                        guard let self, self.visible, let target = self.currentTarget else { return }
                        self.hide()
                        self.show(breakAt: target)
                    }
                }
            }
        }
    }

#if DEBUG
    /// Test seam: identity of the live panels, to assert rebuild vs reuse.
    var _testPanelIDs: [ObjectIdentifier] { panels.map(ObjectIdentifier.init) }
#endif

    /// Shows the glow ramping from now until `breakAt`. Idempotent per
    /// target: evaluate() can run several times inside the glow window
    /// (wake, hold release, pref change) and must not restart the ramp.
    func show(breakAt: Date) {
        if visible, let t = currentTarget, abs(t.timeIntervalSince(breakAt)) < 1 { return }
        hide()
        currentTarget = breakAt
        let duration = max(1, breakAt.timeIntervalSinceNow)
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(
                screen: screen,
                content: AnyView(AmbientGlowView(rampDuration: duration))
            )
            panel.makePassive(level: .statusBar - 1) // under the pill, over normal windows
            return panel
        }
        visible = true
        for panel in panels {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        currentTarget = nil
        guard visible else { return }
        visible = false
        OverlayPanel.dismiss(panels, duration: 0.5)
        panels = []
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
        .onAppear { ramped = true }
    }
}
