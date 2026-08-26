import Foundation

/// One reason breaks are currently held. Detectors publish sets of these.
enum ContextFlag: String {
    case micInUse          // some app is capturing the microphone (call/meeting)
    case cameraInUse       // some app is using the camera
    case screenCaptured    // screen is being shared or recorded
    case mediaPlaying      // video/media playback detected
    case fullscreenApp     // frontmost app is fullscreen
    case deepFocusApp      // frontmost app is on the user's hold list

    var displayName: String {
        switch self {
        case .micInUse: "On a call (microphone)"
        case .cameraInUse: "Camera in use"
        case .screenCaptured: "Screen shared or recording"
        case .mediaPlaying: "Video playing"
        case .fullscreenApp: "Fullscreen app"
        case .deepFocusApp: "Focus app active"
        }
    }

    /// Menu bar symbol for this hold reason. When several reasons are
    /// active, the lowest `priority` value decides the icon.
    var symbolName: String {
        switch self {
        case .micInUse: "person.wave.2"
        case .cameraInUse: "video"
        case .screenCaptured: "rectangle.dashed.badge.record"
        case .mediaPlaying: "play.rectangle"
        case .fullscreenApp: "arrow.up.left.and.arrow.down.right"
        case .deepFocusApp: "scope"
        }
    }

    /// Icon priority when multiple reasons hold at once: call beats screen
    /// share beats camera beats video beats fullscreen beats focus app.
    var priority: Int {
        switch self {
        case .micInUse: 0
        case .screenCaptured: 1
        case .cameraInUse: 2
        case .mediaPlaying: 3
        case .fullscreenApp: 4
        case .deepFocusApp: 5
        }
    }
}

/// A single detection source. Detectors are cheap to start/stop so the user
/// can toggle each one at runtime; `isDetected` is only meaningful while
/// started.
@MainActor
protocol ContextDetector: AnyObject {
    var flag: ContextFlag { get }
    /// Current truth as far as this detector knows. Only meaningful while running.
    var isDetected: Bool { get }
    /// Called when detection state may have changed.
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}
