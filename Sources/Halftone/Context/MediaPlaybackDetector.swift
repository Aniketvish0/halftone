import Foundation
import AppKit
import IOKit.pwr_mgt

/// "Video is playing": some process is producing audio output AND holding a
/// PreventUserIdleDisplaySleep power assertion (video players and browsers
/// playing video do; music apps generally don't). MediaRemote is
/// entitlement-locked since macOS 15.4, so this composite is the modern way.
@MainActor
final class MediaPlaybackDetector: ContextDetector {
    let flag = ContextFlag.mediaPlaying
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var observerID: UUID?
    private let assertionPoller = RepeatingPoller()
    private var displaySleepPIDs: Set<pid_t> = []


    func start() {
        guard observerID == nil else { return }
        AudioProcessMonitor.shared.retainMonitor()
        observerID = AudioProcessMonitor.shared.addObserver { [weak self] in
            self?.recheck()
        }
        // Assertions have no change notification — poll at 10s, but ONLY while
        // audio is playing (gated in recheck); otherwise the timer stays parked.
        recheck()
    }

    func stop() {
        guard let id = observerID else { return }
        AudioProcessMonitor.shared.removeObserver(id)
        AudioProcessMonitor.shared.releaseMonitor()
        observerID = nil
        stopAssertionPolling()
        isDetected = false
    }

    private func recheck() {
        let audioActive = !AudioProcessMonitor.shared.outputPIDs.isEmpty
        if audioActive {
            refreshAssertions()
            startAssertionPollingIfNeeded()
        } else {
            stopAssertionPolling()
            displaySleepPIDs = []
        }
        let now = audioActive && assertionMatchesAudio()
        if now != isDetected {
            isDetected = now
            Trace.mark("media.detected", "\(now)")
            onChange?()
        }
    }

    /// True when a display-sleep assertion belongs to the same app *family*
    /// as an audio-producing process. Chromium-style browsers split the work:
    /// a helper PID plays audio while the main process holds the assertion —
    /// so same-PID matching isn't enough; compare bundle-ID prefixes too
    /// (com.brave.Browser.helper ~ com.brave.Browser).
    private func assertionMatchesAudio() -> Bool {
        let outputPIDs = AudioProcessMonitor.shared.outputPIDs
        if !displaySleepPIDs.isDisjoint(with: outputPIDs) { return true }

        let audioBundles = AudioProcessMonitor.shared.bundleIDs
            .filter { outputPIDs.contains($0.key) }
            .values
        for pid in displaySleepPIDs {
            guard let holder = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            else { continue }
            for audio in audioBundles {
                if audio.hasPrefix(holder) || holder.hasPrefix(audio) { return true }
            }
        }
        return false
    }

    private func startAssertionPollingIfNeeded() {
        assertionPoller.start(interval: 10, leeway: .seconds(2)) { [weak self] in
            self?.recheck()
        }
    }

    private func stopAssertionPolling() {
        assertionPoller.stop()
    }

    private func refreshAssertions() {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            displaySleepPIDs = []
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pids: Set<pid_t> = []
        for (pidNum, assertions) in dict {
            let pid = pid_t(pidNum.int32Value)
            guard pid != ownPID else { continue }
            for a in assertions {
                if a["AssertionTrueType"] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep
                    || a["AssertType"] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep {
                    pids.insert(pid)
                    break
                }
            }
        }
        displaySleepPIDs = pids
    }
}
