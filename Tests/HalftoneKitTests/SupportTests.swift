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
        let debouncer = Debouncer(delay: 0.05)
        let counter = Counter()
        debouncer.schedule { Task { await counter.increment() } }
        try? await Task.sleep(for: .milliseconds(150))
        debouncer.schedule { Task { await counter.increment() } }
        try? await Task.sleep(for: .milliseconds(150))
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

@MainActor
@Suite(.serialized)
struct PreferencesTests {

    @Test func changesCoalesceToOnePostPerRunloopTurn() async {
        let prefs = Preferences.shared
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let original = prefs.warnLeadSec
        for v in [10, 15, 20, 25, 30] { prefs.warnLeadSec = v }
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        #expect(posts == 1, "5 writes in one turn must post once (got \(posts))")
        prefs.warnLeadSec = original
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test func valuesPersistToStore() {
        let prefs = Preferences.shared
        let original = prefs.shortDurationSec
        prefs.shortDurationSec = 45
        #expect(Defaults.store.integer(forKey: "shortDurationSec") == 45)
        prefs.shortDurationSec = original
    }

    @Test func officeDaysRoundTripsAsSet() {
        let prefs = Preferences.shared
        let original = prefs.officeDays
        prefs.officeDays = [1, 7]
        let stored = Set((Defaults.store.array(forKey: "officeDays") as? [Int]) ?? [])
        #expect(stored == [1, 7])
        prefs.officeDays = original
    }
}
