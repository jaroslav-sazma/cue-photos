import Foundation

nonisolated enum PhotoMapStyle: String, CaseIterable, Sendable {
    case standard
    case satellite
    case hybrid
}

nonisolated struct GeoCoordinate: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
}

// gptk's geoLocation: {"coordinates":[latitude, longitude]} in integer degrees × 10^7 (owner's
// devtools capture of lcxiM, 2026-11-24). Kept in that wire format: it rides on every photo of
// the library. An odd shape must cost the photo its pin, never the photo itself, so decoding
// never throws; Int32.min marks a location without usable coordinates.
nonisolated struct GeoLocation: Codable, Hashable, Sendable {
    private var latitudeE7: Int32
    private var longitudeE7: Int32

    init(coordinate: GeoCoordinate?) {
        guard let coordinate,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else {
            latitudeE7 = .min
            longitudeE7 = .min
            return
        }
        latitudeE7 = Int32((coordinate.latitude * 1e7).rounded())
        longitudeE7 = Int32((coordinate.longitude * 1e7).rounded())
    }

    var coordinate: GeoCoordinate? {
        guard latitudeE7 != .min else { return nil }
        return GeoCoordinate(latitude: Double(latitudeE7) / 1e7, longitude: Double(longitudeE7) / 1e7)
    }

    private enum CodingKeys: String, CodingKey { case coordinates }

    init(from decoder: any Decoder) {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let raw = try? container.decodeIfPresent([Double].self, forKey: .coordinates),
              raw.count >= 2 else {
            self.init(coordinate: nil)
            return
        }
        self.init(coordinate: GeoCoordinate(latitude: raw[0] / 1e7, longitude: raw[1] / 1e7))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if coordinate != nil {
            try container.encode([latitudeE7, longitudeE7], forKey: .coordinates)
        }
    }
}

nonisolated struct GeoBounds: Hashable, Sendable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double

    init(_ coordinate: GeoCoordinate) {
        minLatitude = coordinate.latitude
        maxLatitude = coordinate.latitude
        minLongitude = coordinate.longitude
        maxLongitude = coordinate.longitude
    }

    mutating func formUnion(_ other: GeoBounds) {
        minLatitude = min(minLatitude, other.minLatitude)
        maxLatitude = max(maxLatitude, other.maxLatitude)
        minLongitude = min(minLongitude, other.minLongitude)
        maxLongitude = max(maxLongitude, other.maxLongitude)
    }

    static func union(_ all: some Sequence<GeoBounds>) -> GeoBounds? {
        all.reduce(nil) { result, next in
            guard var result else { return next }
            result.formUnion(next)
            return result
        }
    }
}

nonisolated struct GeoRegion: Sendable {
    var center: GeoCoordinate
    var latitudeDelta: Double
    var longitudeDelta: Double

    func contains(_ coordinate: GeoCoordinate) -> Bool {
        guard abs(coordinate.latitude - center.latitude) <= latitudeDelta / 2 else { return false }
        guard longitudeDelta < 360 else { return true }
        // the visible span can cross the antimeridian
        var offset = (coordinate.longitude - center.longitude).truncatingRemainder(dividingBy: 360)
        if offset > 180 {
            offset -= 360
        } else if offset < -180 {
            offset += 360
        }
        return abs(offset) <= longitudeDelta / 2
    }
}

nonisolated struct PhotoMapNode: Identifiable, Sendable {
    nonisolated struct ID: Hashable, Sendable {
        let level: Int
        let index: Int
    }

    let id: ID
    let coordinate: GeoCoordinate
    let bounds: GeoBounds
    let count: Int
    // level 0: grid positions of its photos; coarser levels: indices of level-0 nodes
    let members: [Int32]

    var level: Int { id.level }
}

// Positions into the grid the map was opened from, never copies of its photos: a map of a
// whole library must not hold a second library in memory
nonisolated struct PhotoMapContent: Sendable {
    // cell edge per level in degrees, each 4× the one before; level 0 is ~1 km
    static let cellSizes: [Double] = (0..<7).map { 0.01 * pow(4, Double($0)) }

    var levels: [[PhotoMapNode]]
    var bounds: GeoBounds?
    var locatedCount: Int
    var totalCount: Int

    var isEmpty: Bool { locatedCount == 0 }

    // the finest level whose cells are at least a pin wide, so a screen never holds more
    // annotations than pins fit on it, however large the library
    static func level(forPinDegrees degrees: Double) -> Int {
        cellSizes.firstIndex { $0 >= degrees } ?? cellSizes.count - 1
    }

    func nodes(level: Int, in region: GeoRegion) -> [PhotoMapNode] {
        levels[level].filter { region.contains($0.coordinate) }
    }

    // in view order
    func photoPositions(of nodes: [PhotoMapNode]) -> [Int] {
        var positions = Set<Int>()
        for node in nodes {
            if node.level == 0 {
                positions.formUnion(node.members.lazy.map(Int.init))
            } else {
                for finest in node.members {
                    positions.formUnion(levels[0][Int(finest)].members.lazy.map(Int.init))
                }
            }
        }
        return positions.sorted()
    }
}

nonisolated enum PhotoMapBuilder {
    static func content<Items: RandomAccessCollection<MediaItem>>(
        from items: Items,
        library: [MediaItem] = []
    ) -> PhotoMapContent where Items.Index == Int {
        let borrowed = borrowedCoordinates(for: items, from: library)
        var grouping = Grouping(cellSize: PhotoMapContent.cellSizes[0])
        var located = 0
        for position in items.indices {
            let item = items[position]
            guard let coordinate = item.coordinate ?? borrowed[item.dedupKey] else { continue }
            located += 1
            grouping.add(
                at: coordinate,
                bounds: GeoBounds(coordinate),
                count: 1,
                member: Int32(position)
            )
        }
        let finest = grouping.nodes(level: 0)
        var levels = [finest]
        for level in 1..<PhotoMapContent.cellSizes.count {
            var coarser = Grouping(cellSize: PhotoMapContent.cellSizes[level])
            for node in finest {
                coarser.add(
                    at: node.coordinate,
                    bounds: node.bounds,
                    count: node.count,
                    member: Int32(node.id.index)
                )
            }
            levels.append(coarser.nodes(level: level))
        }
        return PhotoMapContent(
            levels: levels,
            bounds: GeoBounds.union(finest.map(\.bounds)),
            locatedCount: located,
            totalCount: items.count
        )
    }

    // album and trash pages carry no geoLocation; a photo that is also in the library
    // borrows its location from there
    private static func borrowedCoordinates(
        for items: some Collection<MediaItem>,
        from library: [MediaItem]
    ) -> [String: GeoCoordinate] {
        guard !library.isEmpty else { return [:] }
        var missing = Set<String>()
        for item in items where item.coordinate == nil {
            missing.insert(item.dedupKey)
        }
        guard !missing.isEmpty else { return [:] }
        var borrowed: [String: GeoCoordinate] = [:]
        for item in library where missing.contains(item.dedupKey) && borrowed[item.dedupKey] == nil {
            if let coordinate = item.coordinate {
                borrowed[item.dedupKey] = coordinate
            }
        }
        return borrowed
    }

    private struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    private struct Accumulator {
        var latitudeSum = 0.0
        var longitudeSum = 0.0
        var count = 0
        var bounds: GeoBounds?
        var members: [Int32] = []

        mutating func add(coordinate: GeoCoordinate, bounds: GeoBounds, count: Int, member: Int32) {
            latitudeSum += coordinate.latitude * Double(count)
            longitudeSum += coordinate.longitude * Double(count)
            self.count += count
            if self.bounds == nil {
                self.bounds = bounds
            } else {
                self.bounds?.formUnion(bounds)
            }
            members.append(member)
        }
    }

    private struct Grouping {
        let cellSize: Double
        var cells: [Cell: Accumulator] = [:]
        var order: [Cell] = []

        init(cellSize: Double) {
            self.cellSize = cellSize
        }

        mutating func add(at coordinate: GeoCoordinate, bounds: GeoBounds, count: Int, member: Int32) {
            let cell = Cell(
                row: Int((coordinate.latitude / cellSize).rounded(.down)),
                column: Int((coordinate.longitude / cellSize).rounded(.down))
            )
            if cells[cell] == nil { order.append(cell) }
            cells[cell, default: Accumulator()].add(
                coordinate: coordinate,
                bounds: bounds,
                count: count,
                member: member
            )
        }

        func nodes(level: Int) -> [PhotoMapNode] {
            order.enumerated().map { index, cell in
                let group = cells[cell]!
                let weight = Double(group.count)
                return PhotoMapNode(
                    id: PhotoMapNode.ID(level: level, index: index),
                    coordinate: GeoCoordinate(
                        latitude: group.latitudeSum / weight,
                        longitude: group.longitudeSum / weight
                    ),
                    bounds: group.bounds!,
                    count: group.count,
                    members: group.members
                )
            }
        }
    }
}
