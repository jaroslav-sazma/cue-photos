import Foundation

nonisolated enum PhotoSortOrder: String, CaseIterable, Sendable {
    case newestFirst
    case oldestFirst
}

nonisolated enum PhotoGrouping: String, CaseIterable, Sendable {
    case day
    case month
}

nonisolated enum PhotoFilterScope: String, CaseIterable, Sendable {
    case all
    case outsideAnyAlbum
}

nonisolated struct PhotoGridOptions: Sendable {
    var sort: PhotoSortOrder
    var grouping: PhotoGrouping
    var scope: PhotoFilterScope = .all
    var dedupKeysInAlbums: Set<String> = []
    var dateRange: ClosedRange<Date>? = nil
    // Grouping uses the Mac's calendar; per-photo timezoneOffset refinement can come later
    var calendar: Calendar = .current
}

// Shares the source array and stores positions into it: a large timeline must
// stay in memory once, not once per view of it
nonisolated struct PhotoGrid: RandomAccessCollection, Sendable {
    nonisolated struct Section: Identifiable, Hashable, Sendable {
        let id: String
        let start: Date
        var range: Range<Int>
    }

    fileprivate(set) var source: [MediaItem] = []
    fileprivate(set) var order: [Int] = []
    fileprivate(set) var sections: [Section] = []
    let grouping: PhotoGrouping
    let calendar: Calendar
    // new on every full build; an unchanged id promises the grid only grew at the end
    let buildID = UUID()

    init(grouping: PhotoGrouping = .day, calendar: Calendar = .current) {
        self.grouping = grouping
        self.calendar = calendar
    }

    var startIndex: Int { 0 }
    var endIndex: Int { order.count }

    subscript(position: Int) -> MediaItem {
        source[order[position]]
    }

    // formatted per visible header only: thousands of day titles cost more than the sectioning
    func title(of section: Section) -> String {
        switch grouping {
        case .day:
            section.start.formatted(Date.FormatStyle(date: .complete, calendar: calendar, timeZone: calendar.timeZone))
        case .month:
            section.start.formatted(
                Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year()
            ).localizedCapitalized
        }
    }
}

// Builds a PhotoGrid once, then extends it page by page. The timeline streams
// newest first, so a page normally lands after everything already shown and is
// added in O(page). A page that would land anywhere else (oldest-first order, an
// out-of-order page) makes extend return false, and the caller rebuilds.
nonisolated struct PhotoGridBuilder: Sendable {
    let options: PhotoGridOptions
    private(set) var grid: PhotoGrid
    // source items consumed so far; extend only reads what lies beyond
    private(set) var consumedCount = 0
    // every dedupKey consumed, filtered or not: duplicates (page-boundary overlap,
    // shared-album copies) keep their first occurrence, as a full build would
    private var seen: Set<String> = []
    private var buckets: BucketCache

    init(source: [MediaItem], options: PhotoGridOptions) {
        self.options = options
        grid = PhotoGrid(grouping: options.grouping, calendar: options.calendar)
        buckets = BucketCache(calendar: options.calendar, grouping: options.grouping)
        let batch = candidates(in: source, from: 0)
        commit(batch, source: source)
    }

    // source must be the list this grid was built from, grown at the end
    mutating func extend(to source: [MediaItem]) -> Bool {
        guard source.count >= consumedCount else { return false }
        guard source.count > consumedCount else { return true }
        let batch = candidates(in: source, from: consumedCount)
        if let first = batch.kept.first, let last = grid.order.last,
           precedes(source[first], source[last]) {
            return false
        }
        commit(batch, source: source)
        return true
    }

    private struct Batch {
        var newKeys: Set<String>
        var kept: [Int]
    }

    private func candidates(in source: [MediaItem], from start: Int) -> Batch {
        var newKeys = Set<String>(minimumCapacity: source.count - start)
        var kept: [Int] = []
        kept.reserveCapacity(source.count - start)
        for index in start..<source.count {
            let item = source[index]
            guard !seen.contains(item.dedupKey), newKeys.insert(item.dedupKey).inserted else { continue }
            if options.scope == .outsideAnyAlbum, options.dedupKeysInAlbums.contains(item.dedupKey) { continue }
            if let range = options.dateRange, !range.contains(PhotoSectioner.takenDate(of: item)) { continue }
            kept.append(index)
        }
        kept.sort { precedes(source[$0], source[$1]) }
        return Batch(newKeys: newKeys, kept: kept)
    }

    private mutating func commit(_ batch: Batch, source: [MediaItem]) {
        if seen.isEmpty {
            seen = batch.newKeys
        } else {
            seen.formUnion(batch.newKeys)
        }
        grid.source = source
        consumedCount = source.count
        grid.order.reserveCapacity(grid.order.count + batch.kept.count)
        for index in batch.kept {
            let start = buckets.start(for: PhotoSectioner.takenDate(of: source[index]))
            let position = grid.order.count
            grid.order.append(index)
            if let last = grid.sections.indices.last, grid.sections[last].start == start {
                grid.sections[last].range = grid.sections[last].range.lowerBound..<(position + 1)
            } else {
                grid.sections.append(PhotoGrid.Section(
                    id: "\(options.grouping.rawValue)#\(start.timeIntervalSinceReferenceDate)",
                    start: start,
                    range: position..<(position + 1)
                ))
            }
        }
    }

    // burst shots share a timestamp; dedupKey keeps the order stable
    private func precedes(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let ta = PhotoSectioner.takenMilliseconds(of: a), tb = PhotoSectioner.takenMilliseconds(of: b)
        if ta == tb { return a.dedupKey < b.dedupKey }
        return options.sort == .oldestFirst ? ta < tb : ta > tb
    }
}

// Calendar math is the expensive part of grouping; a sorted stream stays inside
// one day or month for long runs, so the last interval answers almost every lookup
private nonisolated struct BucketCache: Sendable {
    let calendar: Calendar
    let component: Calendar.Component
    private var current: (start: Date, end: Date)?

    init(calendar: Calendar, grouping: PhotoGrouping) {
        self.calendar = calendar
        component = grouping == .day ? .day : .month
    }

    mutating func start(for date: Date) -> Date {
        if let current, date >= current.start, date < current.end {
            return current.start
        }
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            current = nil
            return calendar.startOfDay(for: date)
        }
        current = (interval.start, interval.end)
        return interval.start
    }
}

nonisolated enum PhotoSectioner {
    static func takenMilliseconds(of item: MediaItem) -> Double {
        item.timestamp ?? item.creationTimestamp ?? 0
    }

    static func takenDate(of item: MediaItem) -> Date {
        Date(timeIntervalSince1970: takenMilliseconds(of: item) / 1000)
    }
}
