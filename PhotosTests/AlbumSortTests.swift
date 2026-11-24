import Foundation
import Testing

struct AlbumSortTests {
    private func album(_ key: String, newest: Double?, created: Double? = nil, title: String? = nil) -> Album {
        Album(mediaKey: key, title: title ?? key, creationTimestamp: created, timestampRange: PhotoDateRange(newest: newest))
    }

    @Test func timestampRangeDecodesWithNullEnds() throws {
        let json = #"[{"mediaKey":"a","timestampRange":[1700000000000,1760000000000]},{"mediaKey":"b","timestampRange":[null,null]},{"mediaKey":"c"}]"#
        let albums = try JSONDecoder().decode([Album].self, from: Data(json.utf8))
        #expect(albums.map(\.newestPhotoTimestamp) == [1_760_000_000_000, nil, nil])
    }

    @Test func rangeDecodesFromGooglesWrappedEnds() throws {
        let json = #"[{"mediaKey":"q2","timestampRange":[[1793390171000,3600000],[1795560490000,3600000]]},{"mediaKey":"empty","timestampRange":[null,null]}]"#
        let albums = try JSONDecoder().decode([Album].self, from: Data(json.utf8))
        #expect(albums.map(\.newestPhotoTimestamp) == [1_795_560_490_000, nil])
    }

    @Test func newestEndWinsWhateverThePairOrder() throws {
        let json = #"{"mediaKey":"a","timestampRange":[1760000000000,1700000000000]}"#
        let album = try JSONDecoder().decode(Album.self, from: Data(json.utf8))
        #expect(album.newestPhotoTimestamp == 1_760_000_000_000)
    }

    @Test func reshapedRangeKeepsTheAlbum() throws {
        let json = #"{"items":[{"mediaKey":"a","timestampRange":{"x":1}},{"mediaKey":"b","timestampRange":["soon",1760000000000]},{"mediaKey":"c","timestampRange":7}]}"#
        let page = try JSONDecoder().decode(AlbumsPage.self, from: Data(json.utf8))
        #expect(page.droppedItems == 0)
        #expect(page.items.map(\.newestPhotoTimestamp) == [nil, 1_760_000_000_000, nil])
    }

    @Test func mostRecentPhotoSortsNewestFirstAndEmptyAlbumsLast() {
        let albums = [
            album("empty-new", newest: nil, created: 900),
            album("old", newest: 100, created: 800),
            album("new", newest: 300, created: 100),
            album("empty-old", newest: nil, created: 200),
            album("mid", newest: 200, created: 700),
        ]
        #expect(albums.sorted(by: .newestPhotoFirst).map(\.mediaKey) == ["new", "mid", "old", "empty-new", "empty-old"])
    }

    @Test func sharedNewestPhotoFallsBackToCreationTimeThenKey() {
        let albums = [
            album("older", newest: 500, created: 1),
            album("twin-b", newest: 500, created: 2),
            album("twin-a", newest: 500, created: 2),
        ]
        #expect(albums.sorted(by: .newestPhotoFirst).map(\.mediaKey) == ["twin-a", "twin-b", "older"])
    }

    @Test func otherOrdersIgnoreThePhotoDates() {
        let albums = [
            album("b", newest: 100, created: 2, title: "Beta"),
            album("a", newest: 300, created: 1, title: "alpha"),
        ]
        #expect(albums.sorted(by: .recentlyCreated).map(\.mediaKey) == ["b", "a"])
        #expect(albums.sorted(by: .titleAscending).map(\.mediaKey) == ["a", "b"])
    }

    @Test func storedCreationPreferenceSurvivesTheRename() {
        #expect(AlbumSortOrder(rawValue: "newestFirst") == .recentlyCreated)
    }
}
