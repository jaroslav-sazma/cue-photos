import Foundation
import Testing

struct PhotoMapTests {
    private func item(_ key: String, _ latitude: Double? = nil, _ longitude: Double? = nil) -> MediaItem {
        var item = MediaItem(mediaKey: "m-\(key)", dedupKey: key)
        if let latitude, let longitude {
            item.geoLocation = GeoLocation(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
        }
        return item
    }

    private func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 1e-7
    }

    // MARK: decoding

    @Test func libraryItemDecodesE7Coordinates() throws {
        let json = """
        {"mediaKey":"m1","dedupKey":"d1","geoLocation":{"coordinates":[500900000,-144000000],"name":"Somewhere"}}
        """
        let decoded = try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
        let coordinate = try #require(decoded.coordinate)
        #expect(close(coordinate.latitude, 50.09))
        #expect(close(coordinate.longitude, -14.4))
    }

    @Test func missingOrOddLocationKeepsThePhoto() throws {
        let json = """
        {"items":[
         {"mediaKey":"m1","dedupKey":"d1","geoLocation":{}},
         {"mediaKey":"m2","dedupKey":"d2","geoLocation":{"coordinates":[null,null]}},
         {"mediaKey":"m3","dedupKey":"d3","geoLocation":[1,2]},
         {"mediaKey":"m4","dedupKey":"d4","geoLocation":{"coordinates":[900000001,0]}},
         {"mediaKey":"m5","dedupKey":"d5","geoLocation":{"coordinates":[0,-1800000001]}},
         {"mediaKey":"m6","dedupKey":"d6"}
        ]}
        """
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(json.utf8))
        #expect(page.items.count == 6)
        #expect(page.droppedItems == 0)
        #expect(page.items.allSatisfy { $0.coordinate == nil })
    }

    @Test func coordinateLimitsAreInclusive() throws {
        let json = #"{"mediaKey":"m","dedupKey":"d","geoLocation":{"coordinates":[-900000000,1800000000]}}"#
        let coordinate = try #require(try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8)).coordinate)
        #expect(coordinate == GeoCoordinate(latitude: -90, longitude: 180))
    }

    @Test func locationSurvivesEncodingRoundTrip() throws {
        let original = item("d1", 50.0903, 14.4)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(original))
        #expect(decoded.coordinate == original.coordinate)
        let unlocated = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item("d2")))
        #expect(unlocated.coordinate == nil)
    }

    // MARK: places

    @Test func emptyViewHasNoPlaces() {
        let content = PhotoMapBuilder.content(from: [MediaItem]())
        #expect(content.isEmpty)
        #expect(content.bounds == nil)
        #expect(content.levels.allSatisfy { $0.isEmpty })
    }

    @Test func nearbyPhotosShareAPlaceInViewOrder() throws {
        let items = [
            item("a", 50.1001, 14.2001),
            item("b", 48.2001, 16.3001),
            item("c", 50.1009, 14.2009),
            item("d"),
        ]
        let content = PhotoMapBuilder.content(from: items)
        #expect(content.totalCount == 4)
        #expect(content.locatedCount == 3)
        let finest = content.levels[0]
        #expect(finest.map(\.members) == [[0, 2], [1]])
        #expect(close(finest[0].coordinate.latitude, 50.1005))
        #expect(close(finest[0].coordinate.longitude, 14.2005))
        let bounds = try #require(content.bounds)
        #expect(bounds.minLatitude == 48.2001 && bounds.maxLatitude == 50.1009)
    }

    @Test func cellsSplitCorrectlyAroundZero() {
        let items = [
            item("sydney1", -33.8601, 151.2101),
            item("sydney2", -33.8609, 151.2109),
            item("south", -0.001, -0.001),
            item("north", 0.001, -0.001),
            item("east", 0.001, 0.001),
        ]
        let finest = PhotoMapBuilder.content(from: items).levels[0]
        #expect(finest.map(\.members) == [[0, 1], [2], [3], [4]])
    }

    @Test func coarserLevelsMergePlacesWithWeightedCentres() throws {
        let items = [
            item("a", 50.001, 14.001),
            item("b", 50.002, 14.002),
            item("c", 50.031, 14.031),
        ]
        let content = PhotoMapBuilder.content(from: items)
        #expect(content.levels.count == PhotoMapContent.cellSizes.count)
        #expect(content.levels[0].count == 2)
        let merged = try #require(content.levels[1].first)
        #expect(content.levels[1].count == 1)
        #expect(merged.count == 3)
        #expect(merged.members == [0, 1])
        #expect(close(merged.coordinate.latitude, (50.001 + 50.002 + 50.031) / 3))
        #expect(merged.bounds.minLongitude == 14.001 && merged.bounds.maxLongitude == 14.031)
        #expect(content.photoPositions(of: [merged]) == [0, 1, 2])
    }

    @Test func levelFollowsPinSize() {
        #expect(PhotoMapContent.level(forPinDegrees: 0.000_1) == 0)
        #expect(PhotoMapContent.level(forPinDegrees: 0.01) == 0)
        #expect(PhotoMapContent.level(forPinDegrees: 0.011) == 1)
        #expect(PhotoMapContent.level(forPinDegrees: 1_000) == PhotoMapContent.cellSizes.count - 1)
    }

    @Test func regionCrossesTheAntimeridian() {
        let region = GeoRegion(
            center: GeoCoordinate(latitude: 0, longitude: 179),
            latitudeDelta: 10,
            longitudeDelta: 6
        )
        #expect(region.contains(GeoCoordinate(latitude: 0, longitude: -178)))
        #expect(region.contains(GeoCoordinate(latitude: 4, longitude: 177)))
        #expect(!region.contains(GeoCoordinate(latitude: 0, longitude: 175)))
        #expect(!region.contains(GeoCoordinate(latitude: 6, longitude: 179)))
    }

    @Test func worldWideRegionContainsEveryLongitude() {
        let region = GeoRegion(center: GeoCoordinate(latitude: 0, longitude: 0), latitudeDelta: 170, longitudeDelta: 360)
        #expect(region.contains(GeoCoordinate(latitude: 60, longitude: -179.9)))
        #expect(!region.contains(GeoCoordinate(latitude: 89, longitude: 0)))
    }

    @Test func nodesAreFilteredByRegionPerLevel() {
        let items = [item("prague", 50.08, 14.42), item("vienna", 48.2, 16.37), item("lima", -12.04, -77.03)]
        let content = PhotoMapBuilder.content(from: items)
        let centralEurope = GeoRegion(
            center: GeoCoordinate(latitude: 49, longitude: 15),
            latitudeDelta: 4,
            longitudeDelta: 4
        )
        #expect(content.nodes(level: 0, in: centralEurope).map(\.members) == [[0], [1]])
        let world = GeoRegion(center: GeoCoordinate(latitude: 0, longitude: 0), latitudeDelta: 180, longitudeDelta: 360)
        let coarsest = content.nodes(level: PhotoMapContent.cellSizes.count - 1, in: world)
        #expect(coarsest.map(\.count) == [2, 1])
    }

    @Test func photoPositionsAreUniqueAndInViewOrder() {
        let items = [item("a", 50.001, 14.001), item("b", 50.031, 14.031), item("c", 50.002, 14.002)]
        let content = PhotoMapBuilder.content(from: items)
        let finest = content.levels[0]
        #expect(content.photoPositions(of: [finest[1], finest[0]]) == [0, 1, 2])
        #expect(content.photoPositions(of: [content.levels[1][0], finest[0]]) == [0, 1, 2])
    }

    // MARK: library locations

    @Test func albumItemsBorrowLibraryLocations() {
        let library = [item("a", 50.1, 14.2), item("b"), item("a", 10, 10)]
        let album = [item("a"), item("x")]
        let content = PhotoMapBuilder.content(from: album, library: library)
        #expect(content.locatedCount == 1)
        #expect(content.levels[0].map(\.members) == [[0]])
        #expect(content.levels[0].first?.coordinate == GeoCoordinate(latitude: 50.1, longitude: 14.2))
    }

    @Test func ownLocationBeatsTheLibrary() {
        let content = PhotoMapBuilder.content(from: [item("a", 10, 10)], library: [item("a", 50.1, 14.2)])
        #expect(content.levels[0].first?.coordinate == GeoCoordinate(latitude: 10, longitude: 10))
    }

    // MARK: grid subset

    @Test func gridSubsetKeepsSourceAndOrder() {
        let items = (0..<5).map { item("k\($0)") }
        let grid = PhotoGridBuilder(source: items, options: PhotoGridOptions(sort: .newestFirst, grouping: .day)).grid
        let subset = grid.subset([3, 1])
        #expect(subset.map(\.dedupKey) == [grid[3].dedupKey, grid[1].dedupKey])
    }
}
