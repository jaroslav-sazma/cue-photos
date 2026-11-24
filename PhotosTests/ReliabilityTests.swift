import Foundation
import Testing

struct RPCLimiterTests {
    @Test func neverExceedsTheLimitAndServesWaitersInOrder() async throws {
        let limiter = RPCLimiter(limit: 2)
        try await limiter.acquire()
        try await limiter.acquire()

        let third = Task {
            try await limiter.acquire()
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!third.isCancelled)

        await limiter.release()
        let got = try await third.value
        #expect(got)
        await limiter.release()
        await limiter.release()
    }

    @Test func cancelledWaiterThrowsWithoutTakingASlot() async throws {
        let limiter = RPCLimiter(limit: 1)
        try await limiter.acquire()

        let waiter = Task {
            try await limiter.acquire()
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }

        // the held slot is still releasable and reusable
        await limiter.release()
        try await limiter.acquire()
        await limiter.release()
    }
}

struct SelectionPersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "selection-reliability-\(UUID().uuidString).json")
    }

    @Test func clearThenReloadIsEmpty() async {
        let url = tempURL()
        let store = SelectionStore(fileURL: url, saveDelay: .zero)
        store.select([makeTestItem(1, timestamp: 1000)])
        await store.waitForPendingSave()
        store.clear()
        await store.waitForPendingSave()
        let reloaded = SelectionStore(fileURL: url)
        #expect(reloaded.isEmpty)
    }

    @Test func rapidMutationsEndWithTheFinalStateOnDisk() async {
        let url = tempURL()
        let store = SelectionStore(fileURL: url, saveDelay: .zero)
        let item = makeTestItem(1, timestamp: 1000)
        for _ in 0..<6 {
            store.toggle(item)
        }
        store.select([makeTestItem(2, timestamp: 2000)])
        await store.waitForPendingSave()
        let reloaded = SelectionStore(fileURL: url)
        #expect(!reloaded.isSelected("d1"))
        #expect(reloaded.isSelected("d2"))
        #expect(reloaded.count == 1)
    }

    @Test func saveNowWritesSynchronously() {
        let url = tempURL()
        let store = SelectionStore(fileURL: url, saveDelay: .seconds(60))
        store.select([makeTestItem(1, timestamp: 1000)])
        store.saveNow()
        let reloaded = SelectionStore(fileURL: url)
        #expect(reloaded.isSelected("d1"))
    }

    @Test func unreadableFileIsQuarantinedNotOverwritten() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        let store = SelectionStore(fileURL: url, saveDelay: .zero)
        #expect(store.isEmpty)
        let quarantine = url.appendingPathExtension("unreadable")
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct SectionStabilityTests {
    private func grid(_ items: [MediaItem], grouping: PhotoGrouping) -> PhotoGrid {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return PhotoGridBuilder(
            source: items,
            options: PhotoGridOptions(sort: .newestFirst, grouping: grouping, calendar: calendar)
        ).grid
    }

    @Test func equalTimestampsKeepStableOrder() {
        let items = [makeTestItem(2, timestamp: 5000), makeTestItem(1, timestamp: 5000), makeTestItem(3, timestamp: 5000)]
        let a = grid(items, grouping: .day)
        let b = grid(items.reversed(), grouping: .day)
        #expect(a.map(\.dedupKey) == b.map(\.dedupKey))
    }

    @Test func dayAndMonthSectionIdsNeverCollide() {
        let items = [makeTestItem(1, timestamp: 1_790_856_000_000)]
        let day = grid(items, grouping: .day)
        let month = grid(items, grouping: .month)
        #expect(day.sections[0].id != month.sections[0].id)
    }
}

func makeTestItem(_ n: Int, timestamp: Double) -> MediaItem {
    var item = try! JSONDecoder().decode(
        MediaItem.self,
        from: Data(#"{"mediaKey":"m\#(n)","dedupKey":"d\#(n)"}"#.utf8)
    )
    item.timestamp = timestamp
    return item
}

struct SearchNormalizationTests {
    @Test func searchIgnoresCaseAndDiacritics() {
        #expect("Školka 2026".localizedSearchContains("skolka"))
        #expect("Chorvatsko".localizedSearchContains("CHOR"))
        #expect(!"Školka".localizedSearchContains("skolkax"))
    }
}

struct PageTokenGuardTests {
    @Test func stopsOnImmediateRepeat() {
        var tokens = PageTokenGuard()
        #expect(tokens.next("A") == "A")
        #expect(tokens.next("A") == nil)
    }

    @Test func stopsOnLongerCycle() {
        var tokens = PageTokenGuard()
        #expect(tokens.next("A") == "A")
        #expect(tokens.next("B") == "B")
        #expect(tokens.next("C") == "C")
        #expect(tokens.next("A") == nil)
    }

    @Test func passesDistinctTokensAndEndsOnNil() {
        var tokens = PageTokenGuard()
        #expect(tokens.next("A") == "A")
        #expect(tokens.next("B") == "B")
        #expect(tokens.next(nil) == nil)
        #expect(tokens.next("") == nil)
    }
}

struct PublishThrottleTests {
    @Test func firstPublishIsImmediateThenWaitsOnlyForTheRestOfTheInterval() {
        var throttle = PublishThrottle(interval: .seconds(1))
        let start = ContinuousClock.now
        #expect(throttle.delay(at: start) == .zero)
        throttle.didPublish(at: start)
        #expect(throttle.delay(at: start + .milliseconds(400)) == .milliseconds(600))
        #expect(throttle.delay(at: start + .seconds(1)) == .zero)
        #expect(throttle.delay(at: start + .seconds(5)) == .zero)
    }

    @Test func aDelayedPublishRestartsTheInterval() {
        var throttle = PublishThrottle(interval: .seconds(1))
        let start = ContinuousClock.now
        throttle.didPublish(at: start)
        throttle.didPublish(at: start + .milliseconds(1200))
        #expect(throttle.delay(at: start + .milliseconds(1300)) == .milliseconds(900))
    }
}
