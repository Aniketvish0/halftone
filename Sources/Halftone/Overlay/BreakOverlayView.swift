import SwiftUI

/// Full-screen break content: slowly-breathing mesh gradient, system-rendered
/// countdown, Liquid Glass controls. GPU-composited; zero app-side ticking.
struct BreakOverlayView: View {
    let kind: BreakKind
    let endsAt: Date
    let onSkip: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        ZStack {
            AnimatedMesh()
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text(kind == .long ? "Step away for a while" : "Look at something 20 feet away")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 2)

                Text(timerInterval: Date()...max(endsAt, Date()), countsDown: true)
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 3)

                Spacer()

                BreakControls(onSkip: onSkip, onSnooze: onSnooze)
                    .padding(.bottom, 64)
            }
            .padding(40)
        }
    }
}

/// A calm, breathing gradient built from TWO static meshes crossfaded by
/// opacity. Opacity is a CALayer-animatable property, so the render server
/// interpolates it off-process (measured 0.x% CPU). Animating MeshGradient
/// *points* looks equivalent but is re-interpolated by SwiftUI on the CPU
/// every frame: measured 10-19% during a break. Do not go back to it.
private struct AnimatedMesh: View {
    @State private var breathe = false

    private static let colorsA: [Color] = [
        Color(red: 0.05, green: 0.10, blue: 0.24),
        Color(red: 0.10, green: 0.14, blue: 0.36),
        Color(red: 0.05, green: 0.09, blue: 0.22),
        Color(red: 0.12, green: 0.10, blue: 0.34),
        Color(red: 0.22, green: 0.16, blue: 0.48),
        Color(red: 0.10, green: 0.12, blue: 0.34),
        Color(red: 0.04, green: 0.07, blue: 0.18),
        Color(red: 0.08, green: 0.09, blue: 0.26),
        Color(red: 0.04, green: 0.06, blue: 0.16),
    ]

    private static let pointsA: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.42, 0.57], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]
    private static let pointsB: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.58, 0.43], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: Self.pointsA, colors: Self.colorsA)
            MeshGradient(width: 3, height: 3, points: Self.pointsB, colors: Self.colorsA)
                .opacity(breathe ? 1 : 0)
        }
        .animation(.easeInOut(duration: 11).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
    }
}


/// Skip/snooze controls honoring the strictness preference:
/// gentle = immediate; delayed = appear after skipDelaySec; hold = 2s
/// press-and-hold ring on Skip, no snooze.
struct BreakControls: View {
    let onSkip: () -> Void
    let onSnooze: () -> Void

    @State private var buttonsAvailable = false
    @State private var holding = false

    var body: some View {
        // Read live so a Settings change applies to the current break too.
        let strictness = Preferences.shared.strictness
        let delay = TimeInterval(Preferences.shared.skipDelaySec)

        GlassEffectContainer {
            switch strictness {
            case .easy:
                buttons
            case .delayed:
                if buttonsAvailable {
                    buttons.transition(.opacity)
                } else {
                    Text("Controls in a moment…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 12)
                        .task {
                            // task cancels itself when the overlay tears down.
                            try? await Task.sleep(for: .seconds(delay))
                            withAnimation(.easeIn(duration: 0.4)) { buttonsAvailable = true }
                        }
                }
            case .hold:
                holdToSkip
            }
        }
        .controlSize(.large)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button {
                onSnooze()
            } label: {
                Label("Snooze 15 min", systemImage: "clock.arrow.circlepath")
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.glass)

            Button {
                onSkip()
            } label: {
                Label("Skip", systemImage: "forward.end")
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.glass)
        }
    }

    private var holdToSkip: some View {
        // One gesture drives both the ring and the action, so they cannot
        // desync (the old LongPress+Drag pair let trackpad jitter cancel the
        // press while the ring animated to 100% and nothing fired).
        Label("Hold to skip", systemImage: "forward.end")
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                Capsule()
                    .trim(from: 0, to: holding ? 1 : 0)
                    .stroke(.white.opacity(0.9), lineWidth: 2)
                    .animation(holding ? .linear(duration: 2.0) : .easeOut(duration: 0.2),
                               value: holding)
            }
            .glassEffect(.regular, in: .capsule)
            .onLongPressGesture(minimumDuration: 2.0, maximumDistance: 60) {
                onSkip()
            } onPressingChanged: { pressing in
                holding = pressing
            }
    }
}
