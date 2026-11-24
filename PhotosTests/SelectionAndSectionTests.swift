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

extension PhotoGrid {
    var sectionKeys: [[String]] {
        sections.map { $0.range.map { self[$0].dedupKey } }
    }
}

private func build(
    _ items: [MediaItem],
    sort: PhotoSortOrder = .newestFirst,
    grouping: PhotoGrouping = .day,
    scope: PhotoFilterScope = .all,
    dedupKeysInAlbums: Set<String> = [],
    dateRange: ClosedRange<Date>? = nil
) -> PhotoGrid {
    PhotoGridBuilder(source: items, options: PhotoGridOptions(
        sort: sort, grouping: grouping, scope: scope,
        dedupKeysInAlbums: dedupKeysInAlbums, dateRange: dateRange, calendar: utcCalendar()
    )).grid
}

struct PhotoGridTests {
    @Test func groupsByDayNewestFirst() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(1)), makeItem(3, timestamp: dayMs(1) + 1000)]
        let grid = build(items)
        #expect(grid.sectionKeys == [["d3", "d2"], ["d1"]])
        #expect(grid.map(\.dedupKey) == ["d3", "d2", "d1"])
    }

    @Test func groupsByMonthOldestFirst() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(35))]
        let grid = build(items, sort: .oldestFirst, grouping: .month)
        #expect(grid.sectionKeys == [["d1"], ["d2"]])
    }

    @Test func outsideAlbumScopeFiltersByMembership() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(0))]
        let grid = build(items, scope: .outsideAnyAlbum, dedupKeysInAlbums: ["d1"])
        #expect(grid.sectionKeys == [["d2"]])
    }

    @Test func dateRangeFilters() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(10))]
        let range = Date(timeIntervalSince1970: dayMs(5) / 1000)...Date(timeIntervalSince1970: dayMs(15) / 1000)
        let grid = build(items, dateRange: range)
        #expect(grid.sectionKeys == [["d2"]])
    }

    @Test func duplicatesKeepTheirFirstOccurrence() {
        var copy = makeItem(1, timestamp: dayMs(3))
        copy.mediaKey = "album-scoped"
        let grid = build([makeItem(1, timestamp: dayMs(0)), copy])
        #expect(grid.count == 1)
        #expect(grid[0].mediaKey == "m1")
    }

    @Test func titlesFollowTheGrouping() {
        let items = [makeItem(1, timestamp: dayMs(0)), makeItem(2, timestamp: dayMs(1))]
        let days = build(items)
        let months = build(items, grouping: .month)
        #expect(days.title(of: days.sections[0]) != days.title(of: days.sections[1]))
        #expect(months.sections.count == 1)
        #expect(months.title(of: months.sections[0]) != days.title(of: days.sections[0]))
    }
}

// A deterministic generator: failures must reproduce
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

struct PhotoGridBuilderTests {
    // a newest-first stream with burst ties, cross-page duplicates and day gaps
    private func timeline(count: Int, seed: UInt64) -> [MediaItem] {
        var random = SeededGenerator(state: seed)
        var timestamp = dayMs(400)
        var items: [MediaItem] = []
        for n in 0..<count {
            if Int.random(in: 0..<5, using: &random) != 0 {
                timestamp -= Double(Int.random(in: 0...(3 * 86_400_000), using: &random))
            }
            if n > 10, Int.random(in: 0..<20, using: &random) == 0 {
                items.append(items[Int.random(in: (n - 10)..<n, using: &random)])
            } else {
                items.append(makeItem(n, timestamp: timestamp))
            }
        }
        return items
    }

    private func pages(_ items: [MediaItem], seed: UInt64) -> [Int] {
        var random = SeededGenerator(state: seed)
        var ends: [Int] = []
        var end = 0
        while end < items.count {
            end = min(items.count, end + Int.random(in: 1...60, using: &random))
            ends.append(end)
        }
        return ends
    }

    enum Variant: CaseIterable {
        case day, month, outsideAlbums, dateRange, oldestFirst

        var options: PhotoGridOptions {
            var options = PhotoGridOptions(sort: .newestFirst, grouping: .day, calendar: utcCalendar())
            switch self {
            case .day:
                break
            case .month:
                options.grouping = .month
            case .outsideAlbums:
                options.scope = .outsideAnyAlbum
                options.dedupKeysInAlbums = Set((0..<2000).filter { $0 % 3 == 0 }.map { "d\($0)" })
            case .dateRange:
                options.dateRange = Date(timeIntervalSince1970: dayMs(100) / 1000)...Date(timeIntervalSince1970: dayMs(300) / 1000)
            case .oldestFirst:
                options.sort = .oldestFirst
            }
            return options
        }
    }

    @Test(arguments: Variant.allCases)
    func streamedPagesMatchAFullBuild(variant: Variant) {
        let options = variant.options
        for seed in UInt64(1)...5 {
            let items = timeline(count: 2000, seed: seed)
            var builder = PhotoGridBuilder(source: [], options: options)
            for end in pages(items, seed: seed &* 31) {
                let source = Array(items[..<end])
                if !builder.extend(to: source) {
                    builder = PhotoGridBuilder(source: source, options: options)
                }
            }
            let full = PhotoGridBuilder(source: items, options: options).grid
            #expect(builder.grid.sectionKeys == full.sectionKeys, "seed \(seed)")
            #expect(builder.grid.sections.map(\.id) == full.sections.map(\.id), "seed \(seed)")
        }
    }

    @Test func newestFirstStreamExtendsWithoutRebuilding() {
        let items = timeline(count: 1000, seed: 7)
        let options = PhotoGridOptions(sort: .newestFirst, grouping: .day, calendar: utcCalendar())
        var builder = PhotoGridBuilder(source: Array(items[..<100]), options: options)
        let buildID = builder.grid.buildID
        for end in stride(from: 200, through: 1000, by: 100) {
            let extended = builder.extend(to: Array(items[..<end]))
            #expect(extended)
        }
        #expect(builder.grid.buildID == buildID)
    }

    @Test func pageLandingBeforeShownPhotosAsksForARebuild() {
        let options = PhotoGridOptions(sort: .newestFirst, grouping: .day, calendar: utcCalendar())
        let old = makeItem(1, timestamp: dayMs(0))
        var builder = PhotoGridBuilder(source: [old], options: options)
        let extended = builder.extend(to: [old, makeItem(2, timestamp: dayMs(5))])
        #expect(!extended)
        // a refused extend leaves the grid as it was
        #expect(builder.grid.map(\.dedupKey) == ["d1"])
        #expect(builder.consumedCount == 1)
    }

    @Test func tieAcrossPagesSortingEarlierAsksForARebuild() {
        let options = PhotoGridOptions(sort: .newestFirst, grouping: .day, calendar: utcCalendar())
        var builder = PhotoGridBuilder(source: [makeItem(5, timestamp: dayMs(0))], options: options)
        // same timestamp, smaller dedupKey: a full build would put it first
        let extended = builder.extend(to: [makeItem(5, timestamp: dayMs(0)), makeItem(1, timestamp: dayMs(0))])
        #expect(!extended)
    }

    @Test func shrunkSourceAsksForARebuild() {
        let options = PhotoGridOptions(sort: .newestFirst, grouping: .day, calendar: utcCalendar())
        var builder = PhotoGridBuilder(
            source: [makeItem(2, timestamp: dayMs(1)), makeItem(1, timestamp: dayMs(0))],
            options: options
        )
        let extended = builder.extend(to: [makeItem(2, timestamp: dayMs(1))])
        #expect(!extended)
    }
}

struct SelectionItemsTests {
    @Test func liveLibraryItemWinsOverThePersistedEntry() {
        var stale = makeItem(1, timestamp: dayMs(0))
        stale.thumb = "old"
        var live = stale
        live.thumb = "fresh"
        let entries = [
            SelectionStore.Entry(item: stale, album: nil),
            SelectionStore.Entry(item: makeItem(2, timestamp: dayMs(1)), album: nil),
        ]
        let items = SelectionStore.items(for: entries, preferring: [makeItem(9, timestamp: 0), live])
        #expect(items.map(\.dedupKey) == ["d1", "d2"])
        #expect(items[0].thumb == "fresh")
        #expect(items[1].mediaKey == "m2")
    }
}
