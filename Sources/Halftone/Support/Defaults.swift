import Foundation
import CoreGraphics

/// The one preferences store. UserDefaults.standard resolves to the
/// executable-name domain when the binary runs unbundled (--probe,
/// --selftest, dev runs), which silently splits state from the bundled app.
/// Route everything through here so both launch styles share one plist.
/// (AppKit-owned keys like NSStatusItem autosave stay on .standard — AppKit
/// reads that domain directly, and they only matter bundled.)
enum Defaults {
    static let store: UserDefaults = {
        if Bundle.main.bundleIdentifier != nil { return .standard }
        return UserDefaults(suiteName: "me.aniket.halftone") ?? .standard
    }()
}

/// Window-server session flags, shared by lock detection and the
/// screen-sharing fallback.
enum CGSession {
    static func flag(_ key: String) -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict[key] as? Bool) ?? false
    }
}
