import CoreGraphics

nonisolated struct PhotoGridGeometry: Sendable {
    enum Element: Equatable, Sendable {
        case header(section: Int)
        case item(section: Int, item: Int)
    }

    let counts: [Int]
    let columns: Int
    let width: CGFloat
    let headerHeight: CGFloat
    let itemInset: CGFloat
    private(set) var sectionTops: [CGFloat] = []
    private(set) var contentHeight: CGFloat = 0

    init(counts: [Int], columns: Int, width: CGFloat, headerHeight: CGFloat = 32, itemInset: CGFloat = 2) {
        self.counts = counts
        self.columns = max(columns, 1)
        // a zero or negative width (a transient SwiftUI pass) lays out headers only
        self.width = max(width, 0)
        self.headerHeight = headerHeight
        self.itemInset = itemInset
        sectionTops.reserveCapacity(counts.count)
        var y: CGFloat = 0
        for count in counts {
            sectionTops.append(y)
            y += headerHeight + CGFloat((count + self.columns - 1) / self.columns) * side
        }
        contentHeight = y
    }

    var side: CGFloat {
        width / CGFloat(columns)
    }

    func elements(in rect: CGRect) -> [Element] {
        guard !sectionTops.isEmpty, rect.maxY > 0 else { return [] }
        var elements: [Element] = []
        var section = section(atY: rect.minY)
        while section < sectionTops.count, sectionTops[section] < rect.maxY {
            elements.append(.header(section: section))
            if side > 0 {
                let itemsTop = sectionTops[section] + headerHeight
                let firstRow = max(0, Int(((rect.minY - itemsTop) / side).rounded(.down)))
                let lastRow = Int(((rect.maxY - itemsTop) / side).rounded(.down))
                var item = firstRow * columns
                while item < counts[section], item / columns <= lastRow {
                    elements.append(.item(section: section, item: item))
                    item += 1
                }
            }
            section += 1
        }
        return elements
    }

    func itemFrame(section: Int, item: Int) -> CGRect {
        CGRect(
            x: CGFloat(item % columns) * side,
            y: sectionTops[section] + headerHeight + CGFloat(item / columns) * side,
            width: side,
            height: side
        ).insetBy(dx: itemInset, dy: itemInset)
    }

    // a pinned header rides at visibleTop while its section is under it, and is
    // pushed up by the next section's header
    func headerFrame(section: Int, visibleTop: CGFloat) -> CGRect {
        let top = sectionTops[section]
        let bottom = section + 1 < sectionTops.count ? sectionTops[section + 1] : contentHeight
        let y = max(top, min(visibleTop, bottom - headerHeight))
        return CGRect(x: 0, y: y, width: width, height: headerHeight)
    }

    private func section(atY y: CGFloat) -> Int {
        var low = 0, high = sectionTops.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sectionTops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
