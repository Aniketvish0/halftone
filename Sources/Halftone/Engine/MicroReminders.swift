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
        // unrelated Settings tweak restarts both cadences from zero.
        let now = (prefs.blinkEnabled, prefs.blinkIntervalMin,
                   prefs.postureEnabled, prefs.postureIntervalMin)
        guard applied == nil || applied! != now else { return }
        applied = now
        schedule(blink, kind: .blink, enabled: now.0, minutes: now.1)
        schedule(posture, kind: .posture, enabled: now.2, minutes: now.3)
    }

    /// Date-anchored, like the break engine: the next fire time persists
    /// across relaunches and sleeps. Field bug: in-memory repeating timers
    /// reset their phase on every relaunch, and a 45-minute posture interval
    /// on a machine that relaunches or sleeps more often than that NEVER
    /// completed - the user saw zero posture reminders, ever.
    private func schedule(_ poller: RepeatingPoller, kind: Kind, enabled: Bool, minutes: Int) {
        poller.stop()
        let key = anchorKey(kind)
        guard enabled else {
            Defaults.store.removeObject(forKey: key)
            return
        }
        let interval = TimeInterval(max(1, minutes) * 60)
        // Honor a persisted anchor; a past-due anchor fires shortly after
        // launch instead of restarting the whole interval.
        let stored = Defaults.store.object(forKey: key) as? Date
        var nextAt = stored ?? Date().addingTimeInterval(interval)
        if let stored, abs(stored.timeIntervalSinceNow) > interval * 2 {
            nextAt = Date().addingTimeInterval(interval) // stale (interval changed / clock jump)
        }
        Defaults.store.set(nextAt, forKey: key)
        let firstDelay = max(5, nextAt.timeIntervalSinceNow)
        poller.start(interval: interval, leeway: .seconds(30), firstDelay: firstDelay) { [weak self] in
            guard let self else { return }
            Defaults.store.set(Date().addingTimeInterval(interval), forKey: key)
            self.fire(kind)
        }
    }

    private func anchorKey(_ kind: Kind) -> String {
        kind == .blink ? "nextBlinkAt" : "nextPostureAt"
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
