import Foundation
import Testing

private func makeItem(_ n: Int, timestamp: Double) -> MediaItem {
    var item = try! JSONDecoder().decode(
        MediaItem.self,
        from: Data(#"{"mediaKey":"m\#(n)","dedupKey":"d\#(n)"}"#.utf8)
    )
    item.timestamp = timestamp
    return item
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

// 2026-10-01 12:00 UTC in ms, then day offsets
private let baseMs: Double = 1_790_856_000_000
private func dayMs(_ day: Int) -> Double { baseMs + Double(day) * 86_400_000 }

struct SelectionStoreTests {
    private func makeStore(file: URL? = nil) -> (SelectionStore, URL) {
        let url = file ?? FileManager.default.temporaryDirectory
            .appending(path: "selection-test-\(UUID().uuidString).json")
        return (SelectionStore(fileURL: url, saveDelay: .zero), url)
    }

    @Test func toggleSelectsAndDeselects() {
        let (store, _) = makeStore()
        let item = makeItem(1, timestamp: dayMs(0))
        store.toggle(item)
        #expect(store.isSelected("d1"))
        store.toggle(item)
        #expect(!store.isSelected("d1"))
        #expect(store.isEmpty)
    }

    @Test func selectionSurvivesReload() async {
        let (store, url) = makeStore()
        store.select([makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(1))])
        await store.waitForPendingSave()
        let reloaded = SelectionStore(fileURL: url)
        #expect(reloaded.count == 2)
        #expect(reloaded.isSelected("d1") && reloaded.isSelected("d2"))
    }

    @Test func clearReturnsEntriesAndRestorePutsThemBack() {
        let (store, _) = makeStore()
        store.select([makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(1))])
        let removed = store.clear()
        #expect(store.isEmpty)
        #expect(removed.count == 2)
        store.restore(removed)
        #expect(store.count == 2)
    }

    @Test func removeCompletedKeepsTheRestSelected() {
        let (store, _) = makeStore()
        store.select([makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(1)), makeItem(3, timestamp: dayMs(2))])
        store.removeCompleted(["d1", "d3"])
        #expect(store.count == 1)
        #expect(store.isSelected("d2"))
    }

    @Test func entryKeepsAlbumContext() {
        let (store, _) = makeStore()
        let album = try! JSONDecoder().decode(
            Album.self,
            from: Data(#"{"mediaKey":"a1","authKey":"ak","isShared":true}"#.utf8)
        )
        store.select([makeItem(1, timestamp: dayMs(0))], in: album)
        let entry = store.sortedEntries[0]
        #expect(entry.albumMediaKey == "a1")
        #expect(entry.albumAuthKey == "ak")
    }
}

struct PhotoSectionerTests {
    @Test func groupsByDayNewestFirst() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(1)), makeItem(3, timestamp: dayMs(1) + 1000)]
        let sections = PhotoSectioner.sections(from: items, sort: .newestFirst, grouping: .day, calendar: utcCalendar())
        #expect(sections.count == 2)
        #expect(sections[0].items.map(\.dedupKey) == ["d3", "d2"])
        #expect(sections[1].items.map(\.dedupKey) == ["d1"])
    }

    @Test func groupsByMonthOldestFirst() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(35))]
        let sections = PhotoSectioner.sections(from: items, sort: .oldestFirst, grouping: .month, calendar: utcCalendar())
        #expect(sections.count == 2)
        #expect(sections[0].items.map(\.dedupKey) == ["d1"])
        #expect(sections[1].items.map(\.dedupKey) == ["d2"])
    }

    @Test func outsideAlbumScopeFiltersByMembership() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(0))]
        let sections = PhotoSectioner.sections(
            from: items, sort: .newestFirst, grouping: .day,
            scope: .outsideAnyAlbum, dedupKeysInAlbums: ["d1"], calendar: utcCalendar()
        )
        #expect(sections.count == 1)
        #expect(sections[0].items.map(\.dedupKey) == ["d2"])
    }

    @Test func dateRangeFilters() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(10))]
        let range = Date(timeIntervalSince1970: dayMs(5) / 1000)...Date(timeIntervalSince1970: dayMs(15) / 1000)
        let sections = PhotoSectioner.sections(
            from: items, sort: .newestFirst, grouping: .day,
            dateRange: range, calendar: utcCalendar()
        )
        #expect(sections.count == 1)
        #expect(sections[0].items.map(\.dedupKey) == ["d2"])
    }
}
