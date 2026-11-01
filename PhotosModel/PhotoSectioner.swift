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

nonisolated struct PhotoSection: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [MediaItem]

    // identity-only hash: hashing thousands of items per section is wasted work
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// Pure, testable: the stores fetch, this shapes what a grid shows. Grouping uses the
// Mac's calendar; per-photo timezoneOffset refinement can come later.
nonisolated enum PhotoSectioner {
    static func sections(
        from items: [MediaItem],
        sort: PhotoSortOrder,
        grouping: PhotoGrouping,
        scope: PhotoFilterScope = .all,
        dedupKeysInAlbums: Set<String> = [],
        dateRange: ClosedRange<Date>? = nil,
        calendar: Calendar = .current
    ) -> [PhotoSection] {
        // duplicate dedupKeys (page-boundary overlap, shared-album copies) must never
        // reach the diffable snapshot: identical identifiers trap apply()
        var seen = Set<String>()
        var filtered = items.filter { seen.insert($0.dedupKey).inserted }
        if scope == .outsideAnyAlbum {
            filtered = filtered.filter { !dedupKeysInAlbums.contains($0.dedupKey) }
        }
        if let dateRange {
            filtered = filtered.filter { dateRange.contains(takenDate(of: $0)) }
        }

        var buckets: [Date: [MediaItem]] = [:]
        for item in filtered {
            let date = takenDate(of: item)
            let bucket: Date = switch grouping {
            case .day: calendar.startOfDay(for: date)
            case .month: calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
            }
            buckets[bucket, default: []].append(item)
        }

        let ascending = sort == .oldestFirst
        return buckets.keys
            .sorted { ascending ? $0 < $1 : $0 > $1 }
            .map { bucket in
                let sorted = buckets[bucket]!.sorted {
                    let a = takenDate(of: $0), b = takenDate(of: $1)
                    // burst shots share a timestamp; dedupKey keeps the order stable
                    if a == b { return $0.dedupKey < $1.dedupKey }
                    return ascending ? a < b : a > b
                }
                return PhotoSection(
                    id: "\(grouping.rawValue)#\(bucket.timeIntervalSinceReferenceDate)",
                    title: title(for: bucket, grouping: grouping, calendar: calendar),
                    items: sorted
                )
            }
    }

    static func takenDate(of item: MediaItem) -> Date {
        Date(timeIntervalSince1970: (item.timestamp ?? item.creationTimestamp ?? 0) / 1000)
    }

    private static func title(for bucket: Date, grouping: PhotoGrouping, calendar: Calendar) -> String {
        switch grouping {
        case .day:
            bucket.formatted(Date.FormatStyle(date: .complete, calendar: calendar, timeZone: calendar.timeZone))
        case .month:
            bucket.formatted(
                Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year()
            ).localizedCapitalized
        }
    }
}
