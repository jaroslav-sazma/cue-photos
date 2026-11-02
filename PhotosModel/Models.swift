import Foundation

// nonisolated: with MainActor default isolation these DTOs would otherwise be
// unusable from background pagers, decoders and thumbnail workers

nonisolated struct Album: Codable, Identifiable, Hashable, Sendable {
    var mediaKey: String
    var title: String?
    var thumb: String?
    var itemCount: Int?
    var isShared: Bool?
    var authKey: String?
    var creationTimestamp: Double?

    var id: String { mediaKey }
    var displayTitle: String {
        title?.isEmpty == false ? title! : String(localized: "Untitled album")
    }
}

nonisolated enum AlbumSortOrder: String, CaseIterable, Sendable {
    case newestFirst
    case titleAscending
}

nonisolated extension [Album] {
    // Google's list order is not reliably creation-sorted (a fresh album can arrive
    // appended), so newest-first sorts locally by creation time
    func sorted(by order: AlbumSortOrder) -> [Album] {
        switch order {
        case .newestFirst:
            sorted { ($0.creationTimestamp ?? 0) > ($1.creationTimestamp ?? 0) }
        case .titleAscending:
            sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }
}

nonisolated extension String {
    // "skolka" must find "Školka": case- and diacritic-insensitive, locale-aware
    func localizedSearchContains(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}

// one localized, plural-aware spelling of a photo count for headers and subtitles
nonisolated func photoCountText(_ count: Int) -> String {
    String(localized: "\(count) photos")
}

// Google's pagers hand out pageId tokens in a cycle: the last page's token points
// back to the first page (observed on snAcKc, 2026-11-02 — a 3-page album repeats
// 300/300/131 items forever). Pagination must stop at the first token it has
// already used, not just when a token repeats back-to-back.
nonisolated struct PageTokenGuard {
    private var seen: Set<String> = []

    // the token to request next, or nil when pagination is finished or cycling
    mutating func next(_ nextPageId: String?) -> String? {
        guard let nextPageId, !nextPageId.isEmpty else { return nil }
        return seen.insert(nextPageId).inserted ? nextPageId : nil
    }
}

nonisolated struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    var mediaKey: String
    // dedupKey is the stable identity across sources: album pages return
    // album-scoped mediaKeys for the same photo
    var dedupKey: String
    var timestamp: Double?
    var creationTimestamp: Double?
    var thumb: String?
    var resWidth: Int?
    var resHeight: Int?
    var duration: Double?
    var isArchived: Bool?
    var isFavorite: Bool?
    var isOwned: Bool?

    var id: String { mediaKey }

    // thumb is a lh3.googleusercontent.com base url; size parameters follow Google's image
    // serving syntax
    func thumbnailURL(side: Int) -> URL? {
        guard let thumb else { return nil }
        return URL(string: "\(thumb)=w\(side)-h\(side)-c")
    }
}

// Google can reshape single items inside an otherwise fine response; one bad element
// must not sink a page, so page item arrays decode leniently and count their drops
nonisolated struct Lenient<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?

    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}

nonisolated struct AlbumsPage: Decodable, Sendable {
    var items: [Album]
    var droppedItems: Int
    var nextPageId: String?

    init(items: [Album] = [], droppedItems: Int = 0, nextPageId: String? = nil) {
        self.items = items
        self.droppedItems = droppedItems
        self.nextPageId = nextPageId
    }

    private enum CodingKeys: String, CodingKey { case items, nextPageId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try container.decodeIfPresent([Lenient<Album>].self, forKey: .items) ?? []
        items = lenient.compactMap(\.value)
        droppedItems = lenient.count - items.count
        nextPageId = try container.decodeIfPresent(String.self, forKey: .nextPageId)
    }
}

nonisolated struct AlbumItemsPage: Decodable, Sendable {
    var items: [MediaItem]
    var droppedItems: Int
    var nextPageId: String?
    var title: String?
    // the page reports the album under its share token for shared albums — the
    // only form the share-context RPCs (LjmOue) accept as an argument
    var mediaKey: String?

    init(
        items: [MediaItem] = [],
        droppedItems: Int = 0,
        nextPageId: String? = nil,
        title: String? = nil,
        mediaKey: String? = nil
    ) {
        self.items = items
        self.droppedItems = droppedItems
        self.nextPageId = nextPageId
        self.title = title
        self.mediaKey = mediaKey
    }

    private enum CodingKeys: String, CodingKey { case items, nextPageId, title, mediaKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try container.decodeIfPresent([Lenient<MediaItem>].self, forKey: .items) ?? []
        items = lenient.compactMap(\.value)
        droppedItems = lenient.count - items.count
        nextPageId = try container.decodeIfPresent(String.self, forKey: .nextPageId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        mediaKey = try container.decodeIfPresent(String.self, forKey: .mediaKey)
    }
}

nonisolated struct LibraryPage: Decodable, Sendable {
    var items: [MediaItem]
    var droppedItems: Int
    var nextPageId: String?
    var lastItemTimestamp: Double?

    init(items: [MediaItem] = [], droppedItems: Int = 0, nextPageId: String? = nil, lastItemTimestamp: Double? = nil) {
        self.items = items
        self.droppedItems = droppedItems
        self.nextPageId = nextPageId
        self.lastItemTimestamp = lastItemTimestamp
    }

    private enum CodingKeys: String, CodingKey { case items, nextPageId, lastItemTimestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try container.decodeIfPresent([Lenient<MediaItem>].self, forKey: .items) ?? []
        items = lenient.compactMap(\.value)
        droppedItems = lenient.count - items.count
        nextPageId = try container.decodeIfPresent(String.self, forKey: .nextPageId)
        lastItemTimestamp = try container.decodeIfPresent(Double.self, forKey: .lastItemTimestamp)
    }
}

nonisolated struct TrashPage: Decodable, Sendable {
    var items: [MediaItem]
    var droppedItems: Int
    var nextPageId: String?

    init(items: [MediaItem] = [], droppedItems: Int = 0, nextPageId: String? = nil) {
        self.items = items
        self.droppedItems = droppedItems
        self.nextPageId = nextPageId
    }

    private enum CodingKeys: String, CodingKey { case items, nextPageId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try container.decodeIfPresent([Lenient<MediaItem>].self, forKey: .items) ?? []
        items = lenient.compactMap(\.value)
        droppedItems = lenient.count - items.count
        nextPageId = try container.decodeIfPresent(String.self, forKey: .nextPageId)
    }
}

nonisolated struct StorageQuota: Codable, Sendable {
    var usedBytes: Double?
    var totalBytes: Double?
}

// Carries the processed keys, not just counts: after a partial failure or a
// cancellation only the photos that verifiably landed may leave the selection
nonisolated struct BulkWriteReport: Sendable, Equatable {
    var succeededDedupKeys: [String] = []
    var failedDedupKeys: [String] = []
    var cancelled = false
    var firstErrorDescription: String?

    var succeeded: Int { succeededDedupKeys.count }
    var failed: Int { failedDedupKeys.count }
    var fullySucceeded: Bool { failedDedupKeys.isEmpty && !cancelled }
}

nonisolated struct MediaInfo: Codable, Sendable {
    var mediaKey: String?
    var fileName: String?
    var size: Double?
}
