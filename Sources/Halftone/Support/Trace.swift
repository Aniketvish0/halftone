import Foundation

/// Two sinks for one event stream.
///
/// `mark` is developer tracing: stderr only, and only when HALFTONE_TRACE=1.
/// `record` is the durable detection log: always written to
/// ~/Library/Logs/Halftone/events.log, so a call that misbehaves at 9pm can be
/// measured the next morning without having relaunched anything. Only
/// state CHANGES are recorded, so a quiet day writes a handful of lines.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["HALFTONE_TRACE"] == "1"

    private static let lock = NSLock()
    private static var origin: TimeInterval?
    private static var previous: TimeInterval?

    static var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Halftone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.log")
    }

    /// Developer trace: stderr, opt-in.
    static func mark(_ stage: String, _ detail: String = "") {
        guard enabled else { return }
        emitStderr(stage, detail)
    }

    /// Durable event: the log file always, plus stderr when tracing.
    static func record(_ stage: String, _ detail: String = "") {
        if enabled { emitStderr(stage, detail) }
        let line = "\(Self.stamp.string(from: Date())) \(stage) \(detail)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = logURL
        // Roll at 1 MB. One file of history is enough to diagnose a call.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 1_000_000 {
            try? FileManager.default.removeItem(at: url.deletingPathExtension()
                .appendingPathExtension("log.1"))
            try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension()
                .appendingPathExtension("log.1"))
        }
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func emitStderr(_ stage: String, _ detail: String) {
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
