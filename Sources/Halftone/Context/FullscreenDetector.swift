import Foundation
import AppKit
import CoreGraphics

/// "The frontmost app is fullscreen" — window geometry vs screen frames.
/// Geometry/PID/layer need no Screen Recording permission.
///
/// Timing: Space-change/activation events land mid-animation, when the
/// window list can still show the OLD bounds in either direction. So each
/// event triggers a read now plus a debounced settle re-read, and while the
/// flag is TRUE a slow 30s re-verify runs (a stale true holds breaks forever
/// with no event to fix it; a stale false gets corrected by the settle read
/// or the next event). Steady state with no fullscreen app is event-only.
@MainActor
final class FullscreenDetector: ContextDetector {
    let flag = ContextFlag.fullscreenApp
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var tokens: [NSObjectProtocol] = []
    private let verify = RepeatingPoller()
    private let settle = Debouncer(delay: 1.2)

    func start() {
        guard tokens.isEmpty else { return }
        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            tokens.append(wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.eventFired() }
            })
        }
        recheck()
    }

    func stop() {
        let wsnc = NSWorkspace.shared.notificationCenter
        for t in tokens { wsnc.removeObserver(t) }
        tokens = []
        settle.cancel()
        verify.stop()
        isDetected = false
    }

    private func eventFired() {
        Trace.mark("fullscreen.event")
        recheck()
        // The settle re-read covers BOTH stale directions (entered fullscreen
        // but read old windowed bounds, or exited but read old full bounds).
        // Debounced: cmd-tabbing through N apps coalesces to one re-read.
        settle.schedule { [weak self] in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    private func recheck() {
        guard !tokens.isEmpty else { return }
        let now = Self.frontmostIsFullscreen()
        guard now != isDetected else { return }
        isDetected = now
        Trace.mark("fullscreen.detected", "\(now)")
        if now {
            // 30s: a stale-true costs at most a slightly-later break, so slow
            // verification is fine, and a 2h fullscreen movie stays cheap.
            verify.start(interval: 30, leeway: .seconds(5)) { [weak self] in
                self?.recheck()
            }
        } else {
            verify.stop()
        }
        onChange?()
    }

    // MARK: Space-type signal (primary)

    private typealias CIDFn = @convention(c) () -> Int32
    // "Copy" in the SPI name = Create Rule: the CFArray is +1 and ours to
    // release. Returning it as CFArray let Swift bridge without releasing,
    // leaking one array per Space check.
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>

    private static let slsConnection: Int32? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(h, "SLSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: CIDFn.self)()
    }()

    private static let copySpaces: CopySpacesFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(h, "SLSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: CopySpacesFn.self)
    }()

    /// The window server's own answer: is any display's current Space a
    /// fullscreen Space (type 4)? This is the only signal that works on
    /// notched Macs, where a real fullscreen window and a maximized window
    /// have IDENTICAL geometry (both sit below the camera housing, so
    /// neither matches screen.frame). nil = SkyLight unavailable.
    static func anyDisplayOnFullscreenSpace() -> Bool? {
        guard let cid = slsConnection, let copySpaces else { return nil }
        guard let displays = copySpaces(cid).takeRetainedValue() as? [[String: Any]] else { return nil }
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               (current["type"] as? Int) == 4 {
                return true
            }
        }
        return false
    }

    static func frontmostIsFullscreen() -> Bool {
        // Primary: ask the window server about the active Space directly.
        if let spaceAnswer = anyDisplayOnFullscreenSpace() {
            return spaceAnswer
        }
        // Fallback (SkyLight missing): geometry vs full screen frame. Blind
        // on notched Macs but correct on plain displays.
        return frontmostFillsScreenFrame()
    }

    private static func frontmostFillsScreenFrame() -> Bool {
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
