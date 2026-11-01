import Foundation
import Testing

struct ModelDecodingTests {
    @Test func albumDecodesFromBridgeJSON() throws {
        let json = """
        {"mediaKey":"AF1Qip...key","title":"Croatia 2026","thumb":"https://lh3.googleusercontent.com/abc",
         "itemCount":142,"isShared":true,"authKey":"ak123","creationTimestamp":1761000000000}
        """
        let album = try JSONDecoder().decode(Album.self, from: Data(json.utf8))
        #expect(album.mediaKey == "AF1Qip...key")
        #expect(album.displayTitle == "Croatia 2026")
        #expect(album.isShared == true)
        #expect(album.itemCount == 142)
    }

    @Test func untitledAlbumGetsFallbackTitle() throws {
        let album = try JSONDecoder().decode(Album.self, from: Data(#"{"mediaKey":"k"}"#.utf8))
        #expect(album.displayTitle == "Untitled album")
    }

    @Test func mediaItemDecodesAndBuildsThumbnailURL() throws {
        let json = """
        {"mediaKey":"m1","dedupKey":"d1","timestamp":1761000000000,"creationTimestamp":1761000001000,
         "thumb":"https://lh3.googleusercontent.com/xyz","resWidth":4032,"resHeight":3024,"isOwned":true}
        """
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
        let url = item.thumbnailURL(side: 256)
        #expect(url?.absoluteString == "https://lh3.googleusercontent.com/xyz=w256-h256-c")
    }

    @Test func libraryPageToleratesMissingFields() throws {
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(#"{"lastItemTimestamp":123}"#.utf8))
        #expect(page.items.isEmpty)
        #expect(page.droppedItems == 0)
        #expect(page.nextPageId == nil)
        #expect(page.lastItemTimestamp == 123)
    }

    @Test func pagesDropUndecodableItemsInsteadOfFailing() throws {
        let json = """
        {"items":[{"mediaKey":"m1","dedupKey":"d1"},{"unexpected":"shape"},{"mediaKey":"m2","dedupKey":"d2"}],
         "nextPageId":"p2"}
        """
        let page = try JSONDecoder().decode(AlbumItemsPage.self, from: Data(json.utf8))
        #expect(page.items.map(\.mediaKey) == ["m1", "m2"])
        #expect(page.droppedItems == 1)
        #expect(page.nextPageId == "p2")
    }
}
