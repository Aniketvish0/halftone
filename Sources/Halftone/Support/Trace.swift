import Foundation

/// Stage timing for the detection pipeline. Off unless HALFTONE_TRACE=1, in
/// which case every mark prints monotonic milliseconds since the first mark
/// and since the previous one. Safe from any queue.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["HALFTONE_TRACE"] == "1"

    private static let lock = NSLock()
    private static var origin: TimeInterval?
    private static var previous: TimeInterval?

    static func mark(_ stage: String, _ detail: String = "") {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let o = origin ?? now
        origin = o
        let sincePrev = previous.map { now - $0 } ?? 0
        previous = now
        lock.unlock()
        // `now` is machine-wide monotonic uptime, so helper processes that
        // print the same clock correlate exactly with these lines.
        let line = String(format: "[trace up=%.3f %8.1fms +%7.1fms] %@ %@",
                          now, (now - o) * 1000, sincePrev * 1000, stage, detail)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    /// Resets the origin so a new scenario reads from zero.
    static func reset() {
        lock.lock(); origin = nil; previous = nil; lock.unlock()
    }
}
