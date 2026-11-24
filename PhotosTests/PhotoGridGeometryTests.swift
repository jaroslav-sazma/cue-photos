import CoreGraphics
import Testing

struct PhotoGridGeometryTests {
    // 3 columns at 300 pt: 100 pt cells; section 0 has 3 rows, section 1 one row
    private let geometry = PhotoGridGeometry(counts: [7, 3], columns: 3, width: 300)

    @Test func sectionsStackHeadersAndRows() {
        #expect(geometry.sectionTops == [0, 332])
        #expect(geometry.contentHeight == 464)
        #expect(geometry.itemFrame(section: 0, item: 4) == CGRect(x: 102, y: 134, width: 96, height: 96))
        #expect(geometry.itemFrame(section: 1, item: 0) == CGRect(x: 2, y: 366, width: 96, height: 96))
    }

    @Test func rectQueryReturnsOnlyCoveredRows() {
        let elements = geometry.elements(in: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(elements == [.header(section: 0)] + (0..<6).map { .item(section: 0, item: $0) })
    }

    @Test func rectInsideAHeaderReturnsNoItems() {
        let elements = geometry.elements(in: CGRect(x: 0, y: 340, width: 300, height: 10))
        #expect(elements == [.header(section: 1)])
    }

    @Test func rectStartingMidSectionKeepsThatSectionsHeader() {
        let elements = geometry.elements(in: CGRect(x: 0, y: 250, width: 300, height: 150))
        #expect(elements.first == .header(section: 0))
        #expect(elements.contains(.item(section: 0, item: 6)))
        #expect(!elements.contains(.item(section: 0, item: 5)))
        #expect(elements.contains(.header(section: 1)))
    }

    @Test func headerPinsToTheVisibleTopAndIsPushedByTheNextSection() {
        #expect(geometry.headerFrame(section: 0, visibleTop: -20).minY == 0)
        #expect(geometry.headerFrame(section: 0, visibleTop: 100).minY == 100)
        #expect(geometry.headerFrame(section: 0, visibleTop: 310).minY == 300)
        #expect(geometry.headerFrame(section: 1, visibleTop: 100).minY == 332)
    }

    @Test func zeroWidthLaysOutHeadersOnlyWithoutTrapping() {
        let empty = PhotoGridGeometry(counts: [7, 3], columns: 3, width: 0)
        #expect(empty.contentHeight == 64)
        #expect(empty.elements(in: CGRect(x: 0, y: 0, width: 0, height: 500)) == [.header(section: 0), .header(section: 1)])
    }

    @Test func noSectionsNoElements() {
        let empty = PhotoGridGeometry(counts: [], columns: 4, width: 800)
        #expect(empty.elements(in: CGRect(x: 0, y: 0, width: 800, height: 600)).isEmpty)
        #expect(empty.contentHeight == 0)
    }
}
