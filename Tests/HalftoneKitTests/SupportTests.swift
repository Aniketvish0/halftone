import Testing
import Foundation
@testable import HalftoneKit

struct DebouncerTests {

    @Test func burstCollapsesToOneCall() async {
        let debouncer = Debouncer(delay: 0.1)
        let counter = Counter()
        for _ in 0..<20 {
            debouncer.schedule { Task { await counter.increment() } }
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await counter.value == 1, "20 rapid schedules must yield exactly 1 fire")
    }

    @Test func separateBurstsFireSeparately() async {
        // Generous margins: under parallel-suite load a 150ms sleep can
        // resume late enough to merge two 50ms windows (observed flake).
        let debouncer = Debouncer(delay: 0.05)
        let counter = Counter()
        debouncer.schedule { Task { await counter.increment() } }
        try? await Task.sleep(for: .milliseconds(400))
        debouncer.schedule { Task { await counter.increment() } }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await counter.value == 2)
    }

    @Test func cancelPreventsFire() async {
        let debouncer = Debouncer(delay: 0.05)
        let counter = Counter()
        debouncer.schedule { Task { await counter.increment() } }
        debouncer.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await counter.value == 0)
    }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
