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
        let info = ProcessInfo.processInfo
        // Tests must never write the live app's preferences — honor an explicit
        // override, and also auto-detect the SwiftPM test runner so a bare
        // `swift test` (without Scripts/test.sh) is still isolated.
        if let suite = info.environment["HALFTONE_DEFAULTS_SUITE"] {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        if info.processName.contains("PackageTests")
            || info.environment["SWIFTPM_TEST_RUNNER"] != nil
            || info.arguments.contains(where: { $0.contains(".xctest") }) {
            return UserDefaults(suiteName: "me.aniket.halftone.tests") ?? .standard
        }
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


/// Atomic single-instance guard: O_CREAT|O_EXCL lock file holding our PID.
/// Exclusive creation is atomic at the filesystem level (no TOCTOU); a lock
/// left by a dead PID is removed and re-acquired once.
enum SingleInstanceLock {
    private static var lockPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Halftone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock").path
    }

    static func acquire() -> Bool {
        for attempt in 0..<2 {
            let fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                let pid = "\(ProcessInfo.processInfo.processIdentifier)"
                _ = pid.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                atexit { try? FileManager.default.removeItem(atPath: SingleInstanceLock.lockPath) }
                return true
            }
            // Lock exists: live owner keeps it; a dead owner's lock is stale.
            guard attempt == 0,
                  let contents = try? String(contentsOfFile: lockPath, encoding: .utf8),
                  let ownerPID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
                  kill(ownerPID, 0) != 0 else {
                return false
            }
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        return false
    }
}
