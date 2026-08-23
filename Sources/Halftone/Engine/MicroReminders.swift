import AppKit
import SwiftUI

/// Blink and posture micro-reminders: a 3-second soft flash at the top edge
/// with a glyph and a word. Independent cadence from breaks; suppressed while
/// anything else is on screen (break, warning, hold) or the user is away.
@MainActor
final class MicroReminders {
    enum Kind: Hashable {
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

    /// Fires that landed while suppressed, shown the moment suppression ends.
    /// Dropping them starved users who live in holds (fullscreen + video all
    /// day): every 10-minute blink landed suppressed and silently vanished.
    private var pending: [Kind] = []
    private(set) var active = false

#if DEBUG
    /// Test seam: replaces the on-screen flash so tests can count fires.
    var _testPresent: ((Kind) -> Void)?
#endif

    init() {
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyToggles() }
        }
        applyToggles()
    }

    /// Engine calls this whenever the reminder gate changes (state settles
    /// AND hold changes). Timers keep their phase; going active only flushes
    /// what was deferred while suppressed.
    func setActive(_ nowActive: Bool) {
        guard nowActive != active else { return }
        active = nowActive
        guard nowActive, !pending.isEmpty else { return }
        let toShow = pending
        pending = []
        // Stagger so a blink and a posture deferred together don't collide;
        // small lead so the flash doesn't land in the same instant the hold
        // clears (the user is often still mid-motion).
        for (i, kind) in toShow.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 5) { [weak self] in
                self?.fire(kind)
            }
        }
    }

    private func applyToggles() {
        // Every Preferences.changed post lands here; without the guard, an
        // unrelated Settings tweak restarts both cadences from zero. Timers
        // run 24/7 while their feature is on: a 10-minute cadence with 30s
        // leeway is noise next to the always-on 2s screen-capture poll, and
        // stop/start tied to activation kept resetting the phase to zero so
        // an interval never completed during busy days.
        let now = (prefs.blinkEnabled, prefs.blinkIntervalMin,
                   prefs.postureEnabled, prefs.postureIntervalMin)
        guard applied == nil || applied! != now else { return }
        applied = now
        schedule(blink, enabled: now.0, minutes: now.1) { [weak self] in self?.fire(.blink) }
        schedule(posture, enabled: now.2, minutes: now.3) { [weak self] in self?.fire(.posture) }
    }

    private func schedule(_ poller: RepeatingPoller, enabled: Bool, minutes: Int,
                          _ block: @escaping () -> Void) {
        poller.stop()
        guard enabled else { return }
        poller.start(interval: TimeInterval(max(1, minutes) * 60),
                     leeway: .seconds(30), block)
    }

    func fire(_ kind: Kind) {
        if isSuppressed?() ?? false {
            // Defer, once per kind: shown when the hold/break/absence ends.
            if !pending.contains(kind) { pending.append(kind) }
            return
        }
#if DEBUG
        if let seam = _testPresent { seam(kind); return }
#endif
        guard flashPanel == nil, let screen = NSScreen.main else { return }
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
