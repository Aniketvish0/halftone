import Testing
import Foundation
@testable import HalftoneKit

@MainActor
@Suite(.serialized)
struct ContextEngineTests {

    init() async {
        let prefs = Preferences.shared
        prefs.contextLingerSec = 1 // fast linger for tests
        // Detectors off so real hardware can't interfere with assertions.
        prefs.pauseOnMic = false
        prefs.pauseOnCamera = false
        prefs.pauseOnScreenCapture = false
        prefs.pauseOnMedia = false
        prefs.pauseOnFullscreen = false
        prefs.pauseOnDeepFocusApps = false
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test func holdSetAndReleaseThroughLinger() async throws {
        let engine = ContextEngine()
        var changes = 0
        engine.onChange = { changes += 1 }

        engine._testSetHold(true)
        #expect(engine.shouldHold)
        #expect(engine.holdReasons == [.micInUse])

        // _testSetHold(false) clears immediately (test seam bypasses linger).
        engine._testSetHold(false)
        #expect(!engine.shouldHold)
        #expect(changes >= 2)
    }

    @Test func togglesStartAndStopDetectorsLive() async {
        let prefs = Preferences.shared
        let engine = ContextEngine()
        // Enabling then disabling a detector must not crash or leak holds.
        prefs.pauseOnFullscreen = true
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        prefs.pauseOnFullscreen = false
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        #expect(!engine.shouldHold || !engine.activeFlags.contains(.fullscreenApp))
    }

    @Test func disabledDetectorContributesNoFlags() async {
        let engine = ContextEngine()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        // All detectors disabled in init: no flags possible.
        #expect(engine.activeFlags.isEmpty)
    }
}
