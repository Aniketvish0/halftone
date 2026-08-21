import Foundation
import AppKit
import CoreGraphics

/// "The frontmost app is fullscreen" — window geometry vs screen frames.
/// Re-evaluates only on Space changes and app activations (event-driven,
/// no polling). Geometry/PID/layer need no Screen Recording permission.
/// Doubles as the deep-focus-app detector (user-listed bundle IDs).
@MainActor
final class FullscreenDetector: ContextDetector {
    let flag = ContextFlag.fullscreenApp
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var tokens: [NSObjectProtocol] = []
    private var verifyTimer: DispatchSourceTimer?

    func start() {
        guard tokens.isEmpty else { return }
        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            tokens.append(wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recheck()
                    // Fullscreen exit animates; geometry read at the event can
                    // still see the old full-frame bounds. Re-read after it
                    // settles so a stale reading can't stick.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.recheck()
                    }
                }
            })
        }
        recheck()
    }

    func stop() {
        let wsnc = NSWorkspace.shared.notificationCenter
        for t in tokens { wsnc.removeObserver(t) }
        tokens = []
        stopVerify()
        isDetected = false
    }

    private func recheck() {
        guard !tokens.isEmpty else { return }
        let now = Self.frontmostIsFullscreen()
        if now != isDetected {
            isDetected = now
            onChange?()
        }
        // A wrongly-true flag holds breaks forever with no event to fix it.
        // While the flag is on, cheaply re-verify every 5s; the timer exists
        // only in that state, so the normal case stays event-driven.
        if isDetected { startVerify() } else { stopVerify() }
    }

    private func startVerify() {
        guard verifyTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.recheck() }
        t.resume()
        verifyTimer = t
    }

    private func stopVerify() {
        verifyTimer?.cancel()
        verifyTimer = nil
    }

    static func frontmostIsFullscreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }

        // A true fullscreen Space covers the FULL screen frame (menu bar
        // area included). A merely maximized window covers visibleFrame —
        // deliberately NOT matched (that was a false-positive source).
        let screenSizes = NSScreen.screens.map(\.frame.size)

        for w in info {
            guard (w["kCGWindowOwnerPID"] as? pid_t) == front.processIdentifier,
                  (w["kCGWindowLayer"] as? Int ?? 1) <= 0,
                  let b = w["kCGWindowBounds"] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"] else { continue }
            for s in screenSizes {
                if abs(s.width - width) < 2 && abs(s.height - height) < 2 {
                    return true
                }
            }
        }
        return false
    }
}

/// "The frontmost app is on the user's hold list."
@MainActor
final class DeepFocusAppDetector: ContextDetector {
    let flag = ContextFlag.deepFocusApp
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.recheck(frontmost: app)
            }
        }
        recheck(frontmost: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        token = nil
        isDetected = false
    }

    func listChanged() {
        recheck(frontmost: NSWorkspace.shared.frontmostApplication)
    }

    private func recheck(frontmost: NSRunningApplication?) {
        let now = frontmost?.bundleIdentifier.map(Preferences.shared.deepFocusApps.contains) ?? false
        if now != isDetected {
            isDetected = now
            onChange?()
        }
    }
}
