import Foundation

/// One reason breaks are currently held. Detectors publish sets of these.
enum ContextFlag: String, CaseIterable, Codable {
    case micInUse          // some app is capturing the microphone (call/meeting)
    case cameraInUse       // some app is using the camera
    case screenCaptured    // screen is being shared or recorded
    case mediaPlaying      // video/media playback detected
    case fullscreenApp     // frontmost app is fullscreen
    case deepFocusApp      // frontmost app is on the user's hold list
    case outsideOfficeHours

    var displayName: String {
        switch self {
        case .micInUse: "On a call (microphone)"
        case .cameraInUse: "Camera in use"
        case .screenCaptured: "Screen shared or recording"
        case .mediaPlaying: "Video playing"
        case .fullscreenApp: "Fullscreen app"
        case .deepFocusApp: "Focus app active"
        case .outsideOfficeHours: "Outside office hours"
        }
    }
}

/// A single detection source. Detectors are cheap to start/stop so the user
/// can toggle each one at runtime; `isActive` reflects the current toggle.
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
