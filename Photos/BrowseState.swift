import Foundation
import Observation

enum BrowseDestination: Equatable {
    case library
    case album(Album)
    case trash
    case selection
}

// View preferences persist across launches; navigation does not
@Observable
final class BrowseState {
    // non-library destinations ignore the scope via BrowserView.effectiveScope; the
    // stored preference survives the detour
    var destination: BrowseDestination = .library

    var sort: PhotoSortOrder {
        didSet { defaults.set(sort.rawValue, forKey: "browse.sort") }
    }
    var grouping: PhotoGrouping {
        didSet { defaults.set(grouping.rawValue, forKey: "browse.grouping") }
    }
    var columns: Int {
        didSet { defaults.set(columns, forKey: "browse.columns") }
    }
    var scope: PhotoFilterScope {
        didSet { defaults.set(scope.rawValue, forKey: "browse.scope") }
    }
    var albumSort: AlbumSortOrder {
        didSet { defaults.set(albumSort.rawValue, forKey: "browse.albumSort") }
    }

    var dateRangeEnabled = false
    var dateFrom = Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now
    var dateTo = Date.now
    var albumSearch = ""

    // whole days, inclusive at both ends, regardless of the clock time the pickers carry
    var dateRange: ClosedRange<Date>? {
        guard dateRangeEnabled else { return nil }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: min(dateFrom, dateTo))
        let endOfTo = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(dateFrom, dateTo)))?
            .addingTimeInterval(-0.001) ?? max(dateFrom, dateTo)
        return from...endOfTo
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sort = PhotoSortOrder(rawValue: defaults.string(forKey: "browse.sort") ?? "") ?? .newestFirst
        grouping = PhotoGrouping(rawValue: defaults.string(forKey: "browse.grouping") ?? "") ?? .day
        let storedColumns = defaults.integer(forKey: "browse.columns")
        columns = (2...12).contains(storedColumns) ? storedColumns : 6
        scope = PhotoFilterScope(rawValue: defaults.string(forKey: "browse.scope") ?? "") ?? .all
        albumSort = AlbumSortOrder(rawValue: defaults.string(forKey: "browse.albumSort") ?? "") ?? .newestFirst
    }

    func resetFilters() {
        scope = .all
        dateRangeEnabled = false
        albumSearch = ""
    }
}
