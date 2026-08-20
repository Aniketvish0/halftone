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

                GlassEffectContainer {
                    HStack(spacing: 14) {
                        Button {
                            onSnooze()
                        } label: {
                            Label("Snooze 15 min", systemImage: "clock.arrow.circlepath")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)

                        Button {
                            onSkip()
                        } label: {
                            Label("Skip", systemImage: "forward.end")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
                .padding(.bottom, 64)
            }
            .padding(40)
        }
    }
}

/// A calm, slowly-drifting mesh gradient. Animated at 4 fps via TimelineView —
/// far below display refresh; the motion is glacial by design.
private struct AnimatedMesh: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let drift = Float(sin(t / 9)) * 0.08
            let drift2 = Float(cos(t / 13)) * 0.07

            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + drift, 0.5 + drift2], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
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
            )
        }
    }
}
