import Foundation

/// Coalesces bursts of events into one callback. Built on a single rescheduled
/// DispatchSourceTimer: re-arming moves the pending wakeup instead of leaving
/// a cancelled-but-enqueued work item to fire as a no-op (the DispatchWorkItem
/// pattern costs one wakeup per event; this costs one per burst).
final class Debouncer: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ block: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let timer {
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler(handler: block)
        } else {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + delay)
            t.setEventHandler(handler: block)
            t.resume()
            timer = t
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}
