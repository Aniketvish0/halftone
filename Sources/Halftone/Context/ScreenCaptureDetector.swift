import Foundation
import CoreGraphics

/// "The screen is being captured" — covers Zoom/Meet/Teams shares, OBS,
/// QuickTime recordings, ScreenCaptureKit clients. Uses the private SkyLight
/// SLSIsScreenWatcherPresent (the same signal behind the system's purple
/// capture indicator), resolved via dlsym so a missing symbol degrades to the
/// public (but weaker) CGSSessionScreenIsShared key.
@MainActor
final class ScreenCaptureDetector: ContextDetector {
    let flag = ContextFlag.screenCaptured
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var timer: DispatchSourceTimer?

    private typealias WatcherFn = @convention(c) () -> Bool
    private static let isWatcherPresent: WatcherFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let sym = dlsym(handle, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(sym, to: WatcherFn.self)
    }()

    func start() {
        guard timer == nil else { return }
        // A single window-server call every 2s is negligible; notification
        // registration (SLSRegisterNotifyProc 1502/1503) has no unregister,
        // which fights runtime toggling — so poll-only, cheap and correct.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.recheck() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isDetected = false
    }

    private func recheck() {
        let now: Bool
        if let fn = Self.isWatcherPresent {
            now = fn()
        } else if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            now = (dict["CGSSessionScreenIsShared"] as? Bool) ?? false
        } else {
            now = false
        }
        if now != isDetected {
            isDetected = now
            onChange?()
        }
    }
}
