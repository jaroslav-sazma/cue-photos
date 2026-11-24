import AppKit
import SwiftUI

// A classic data source and an arithmetic layout instead of diffable snapshots and
// the compositional layout: those cost seconds per update at a few hundred
// thousand photos (measured 2026-11-24: 9 s to build a 270k-item snapshot, ~0.2 s
// per layout pass); this stays in single milliseconds at that size.
struct PhotoGridView: NSViewRepresentable {
    let grid: PhotoGrid
    // a new identity is new content, shown from the top; an unchanged one keeps
    // the viewport while pages stream in
    let contentIdentity: String
    let columns: Int
    let selectionRevision: Int
    let isSelected: (String) -> Bool
    let thumbnails: ThumbnailLoader
    // the index is a hint into this view's grid; the item is the truth, since the
    // caller can hold a newer grid before the next update reaches this view
    let onToggle: (_ item: MediaItem, _ index: Int, _ rangeSelect: Bool) -> Void
    let onSelectSection: ([MediaItem]) -> Void
    let onOpenLightbox: (_ item: MediaItem, _ index: Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = PhotoGridLayout()
        layout.columns = columns
        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(
            PhotoCellItem.self,
            forItemWithIdentifier: PhotoCellItem.identifier
        )
        collectionView.register(
            PhotoSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: PhotoSectionHeaderView.identifier
        )
        context.coordinator.attach(to: collectionView, layout: layout)

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewPrefetching {
        var parent: PhotoGridView

        private weak var collectionView: NSCollectionView?
        private weak var layout: PhotoGridLayout?
        private var grid = PhotoGrid()
        private var appliedIdentity: String?
        private var appliedColumns: Int
        private var appliedSelectionRevision: Int
        private var prefetchTasks: [String: Task<Void, Never>] = [:]

        init(_ parent: PhotoGridView) {
            self.parent = parent
            appliedColumns = parent.columns
            appliedSelectionRevision = parent.selectionRevision
        }

        func attach(to collectionView: NSCollectionView, layout: PhotoGridLayout) {
            self.collectionView = collectionView
            self.layout = layout
            collectionView.dataSource = self
            collectionView.prefetchDataSource = self
        }

        func update() {
            guard let collectionView, let layout else { return }

            if parent.columns != appliedColumns {
                appliedColumns = parent.columns
                layout.columns = parent.columns
                layout.invalidateLayout()
                // new size bucket: visible cells refetch at the right resolution
                reconfigureVisibleCells()
            }

            let new = parent.grid
            let old = grid
            if new.buildID != old.buildID || new.count != old.count || new.sections.count != old.sections.count {
                let identityChanged = parent.contentIdentity != appliedIdentity
                appliedIdentity = parent.contentIdentity
                // a same-build grid only grows; anything else must not reach a batch
                // insert, which would throw on counts that shrank
                if !identityChanged, new.buildID == old.buildID, !old.sections.isEmpty,
                   new.count >= old.count, new.sections.count >= old.sections.count {
                    insertTail(of: new, after: old, in: collectionView)
                } else {
                    for task in prefetchTasks.values { task.cancel() }
                    prefetchTasks = [:]
                    grid = new
                    layout.sectionCounts = new.sections.map(\.range.count)
                    // after a full reload every visible cell is configured afresh; the
                    // synchronous cache read keeps already-loaded photos from blanking
                    collectionView.reloadData()
                    if identityChanged {
                        scrollToTop()
                    }
                }
            } else {
                grid = new
            }

            if parent.selectionRevision != appliedSelectionRevision {
                appliedSelectionRevision = parent.selectionRevision
                // only instantiated cells need the new state; the rest read it when made
                for cell in preparedCells() {
                    guard let key = cell.representedKey else { continue }
                    cell.setSelectedAppearance(parent.isSelected(key))
                }
            }
        }

        // The builder only grows a grid with an unchanged buildID at the end: the
        // last section can gain items and new sections can follow. Inserting just
        // that tail leaves every visible cell and pinned header untouched.
        private func insertTail(of new: PhotoGrid, after old: PhotoGrid, in collectionView: NSCollectionView) {
            // NSCollectionView validates a batch against the counts it has cached;
            // reading them here makes sure they are the old ones, not lazily the new
            _ = collectionView.numberOfSections
            let lastOld = old.sections.count - 1
            _ = collectionView.numberOfItems(inSection: lastOld)
            let oldCount = old.sections[lastOld].range.count
            let newCount = new.sections[lastOld].range.count
            grid = new
            layout?.sectionCounts = new.sections.map(\.range.count)
            collectionView.performBatchUpdates {
                if newCount > oldCount {
                    collectionView.insertItems(at: Set((oldCount..<newCount).map {
                        IndexPath(item: $0, section: lastOld)
                    }))
                }
                if new.sections.count > old.sections.count {
                    collectionView.insertSections(IndexSet(old.sections.count..<new.sections.count))
                }
            }
        }

        private func scrollToTop() {
            guard let scrollView = collectionView?.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            grid.sections.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            grid.sections.indices.contains(section) ? grid.sections[section].range.count : 0
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: PhotoCellItem.identifier, for: indexPath)
            if let cell = cell as? PhotoCellItem, let index = position(of: indexPath) {
                configure(cell, with: grid[index], pixelSize: thumbnailPixelSize())
            }
            return cell
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: PhotoSectionHeaderView.identifier,
                for: indexPath
            )
            if let header = view as? PhotoSectionHeaderView, grid.sections.indices.contains(indexPath.section) {
                let section = grid.sections[indexPath.section]
                header.title = grid.title(of: section)
                // resolved at click time: a header outlives the grid that made it
                let sectionID = section.id
                header.onSelectAll = { [weak self] in self?.selectAll(inSection: sectionID) }
            }
            return view
        }

        private func configure(_ cell: PhotoCellItem, with item: MediaItem, pixelSize: Int) {
            cell.configure(
                item: item,
                selected: parent.isSelected(item.dedupKey),
                pixelSize: pixelSize,
                thumbnails: parent.thumbnails,
                onToggle: { [weak self, weak cell] rangeSelect in
                    guard let self, let cell, let index = self.position(of: cell) else { return }
                    self.parent.onToggle(self.grid[index], index, rangeSelect)
                },
                onOpenLightbox: { [weak self, weak cell] in
                    guard let self, let cell, let index = self.position(of: cell) else { return }
                    self.parent.onOpenLightbox(self.grid[index], index)
                }
            )
        }

        private func reconfigureVisibleCells() {
            guard let collectionView else { return }
            let pixelSize = thumbnailPixelSize()
            for cell in preparedCells() {
                guard let indexPath = collectionView.indexPath(for: cell),
                      let index = position(of: indexPath) else { continue }
                configure(cell, with: grid[index], pixelSize: pixelSize)
            }
        }

        // AppKit keeps items alive for a prepared rect beyond the visible one; a cell
        // there would scroll in showing a stale state
        private func preparedCells() -> [PhotoCellItem] {
            guard let collectionView, let layout = collectionView.collectionViewLayout else { return [] }
            let rect = collectionView.preparedContentRect.union(collectionView.visibleRect)
            return layout.layoutAttributesForElements(in: rect).compactMap { attributes in
                guard attributes.representedElementCategory == .item,
                      let indexPath = attributes.indexPath else { return nil }
                return collectionView.item(at: indexPath) as? PhotoCellItem
            }
        }

        private func thumbnailPixelSize() -> Int {
            let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? 1200
            let cellPoints = width / CGFloat(max(appliedColumns, 1))
            let scale = collectionView?.window?.backingScaleFactor ?? 2
            let pixels = Int(cellPoints * scale)
            // a few fixed buckets keep the thumbnail cache hit rate high
            let buckets = [128, 256, 384, 512, 768, 1024]
            return buckets.first { $0 >= pixels } ?? 1024
        }

        // MARK: prefetch

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let pixelSize = thumbnailPixelSize()
            let loader = parent.thumbnails
            for indexPath in indexPaths {
                guard let index = position(of: indexPath) else { continue }
                let item = grid[index]
                guard let base = item.thumb, prefetchTasks[item.dedupKey] == nil else { continue }
                let key = item.dedupKey
                prefetchTasks[key] = Task(priority: .utility) { [weak self] in
                    _ = try? await loader.thumbnail(base: base, pixelSize: pixelSize, cacheKey: key)
                    self?.prefetchTasks.removeValue(forKey: key)
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths {
                guard let index = position(of: indexPath) else { continue }
                prefetchTasks.removeValue(forKey: grid[index].dedupKey)?.cancel()
            }
        }

        // MARK: lookup

        private func selectAll(inSection sectionID: String) {
            guard let section = grid.sections.first(where: { $0.id == sectionID }) else { return }
            let items = section.range.map { grid[$0] }
            guard !items.isEmpty else { return }
            parent.onSelectSection(items)
        }

        private func position(of indexPath: IndexPath) -> Int? {
            guard grid.sections.indices.contains(indexPath.section) else { return nil }
            let range = grid.sections[indexPath.section].range
            let index = range.lowerBound + indexPath.item
            return range.contains(index) ? index : nil
        }

        // resolved when clicked, not when configured: positions shift on a rebuild
        private func position(of cell: PhotoCellItem) -> Int? {
            guard let indexPath = collectionView?.indexPath(for: cell),
                  let index = position(of: indexPath),
                  grid[index].dedupKey == cell.representedKey else { return nil }
            return index
        }
    }
}

final class PhotoGridLayout: NSCollectionViewLayout {
    var columns = 6
    var sectionCounts: [Int] = [] {
        didSet { geometryIsStale = true }
    }

    // queries read only the geometry prepare() built: counts and columns can
    // change before the collection view gets to invalidate the layout
    private var geometry = PhotoGridGeometry(counts: [], columns: 1, width: 0)
    private var geometryIsStale = true

    override func prepare() {
        super.prepare()
        let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 0
        guard geometryIsStale || geometry.width != width || geometry.columns != max(columns, 1) else { return }
        geometry = PhotoGridGeometry(counts: sectionCounts, columns: columns, width: width)
        geometryIsStale = false
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: geometry.width, height: geometry.contentHeight)
    }

    // pinned headers move with every scroll; the geometry is reused as is
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let visibleTop = self.visibleTop
        return geometry.elements(in: rect).map { element in
            switch element {
            case .header(let section): headerAttributes(section: section, visibleTop: visibleTop)
            case .item(let section, let item): itemAttributes(IndexPath(item: item, section: section))
            }
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard geometry.counts.indices.contains(indexPath.section) else { return nil }
        return itemAttributes(indexPath)
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == NSCollectionView.elementKindSectionHeader,
              geometry.counts.indices.contains(indexPath.section) else { return nil }
        return headerAttributes(section: indexPath.section, visibleTop: visibleTop)
    }

    // the clip view's origin, not visibleRect: visibleRect is clamped to the
    // document, so under a top content inset it would pin headers an inset too low
    private var visibleTop: CGFloat {
        guard let scrollView = collectionView?.enclosingScrollView else { return 0 }
        return scrollView.contentView.bounds.minY + scrollView.contentInsets.top
    }

    private func itemAttributes(_ indexPath: IndexPath) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = geometry.itemFrame(section: indexPath.section, item: indexPath.item)
        return attributes
    }

    private func headerAttributes(section: Int, visibleTop: CGFloat) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            with: IndexPath(item: 0, section: section)
        )
        attributes.frame = geometry.headerFrame(section: section, visibleTop: visibleTop)
        attributes.zIndex = 2
        return attributes
    }
}

final class PhotoCellItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCellItem")

    private(set) var representedKey: String?
    private var shownPixelSize: Int?
    private var loadTask: Task<Void, Never>?

    private let imageLayer = CALayer()
    private let dimLayer = CALayer()
    private let checkView = NSImageView()
    private let magnifierBacking = NSVisualEffectView()
    private let magnifierButton = NSButton()
    private var onToggle: ((_ rangeSelect: Bool) -> Void)?
    private var onOpenLightbox: (() -> Void)?

    override func loadView() {
        let container = PhotoCellClickView()
        container.wantsLayer = true
        container.onClick = { [weak self] rangeSelect in self?.onToggle?(rangeSelect) }
        container.magnifier = magnifierButton
        view = container

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 6
        imageLayer.backgroundColor = NSColor.quaternarySystemFill.cgColor
        view.layer?.addSublayer(imageLayer)

        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        dimLayer.cornerRadius = 6
        dimLayer.isHidden = true
        view.layer?.addSublayer(dimLayer)

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.contentTintColor = .white
        checkView.wantsLayer = true
        view.addSubview(checkView)

        magnifierBacking.translatesAutoresizingMaskIntoConstraints = false
        magnifierBacking.material = .popover
        magnifierBacking.blendingMode = .withinWindow
        magnifierBacking.state = .active
        magnifierBacking.wantsLayer = true
        magnifierBacking.layer?.cornerRadius = 14
        magnifierBacking.layer?.masksToBounds = true
        view.addSubview(magnifierBacking)

        magnifierButton.translatesAutoresizingMaskIntoConstraints = false
        magnifierButton.isBordered = false
        magnifierButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: String(localized: "Open preview")
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        magnifierButton.contentTintColor = .labelColor
        magnifierButton.target = self
        magnifierButton.action = #selector(openLightbox)
        view.addSubview(magnifierButton)

        NSLayoutConstraint.activate([
            checkView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            checkView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            checkView.widthAnchor.constraint(equalToConstant: 22),
            checkView.heightAnchor.constraint(equalToConstant: 22),
            magnifierButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            magnifierButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            magnifierButton.widthAnchor.constraint(equalToConstant: 28),
            magnifierButton.heightAnchor.constraint(equalToConstant: 28),
            magnifierBacking.centerXAnchor.constraint(equalTo: magnifierButton.centerXAnchor),
            magnifierBacking.centerYAnchor.constraint(equalTo: magnifierButton.centerYAnchor),
            magnifierBacking.widthAnchor.constraint(equalToConstant: 28),
            magnifierBacking.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds
        dimLayer.frame = view.bounds
        imageLayer.contentsScale = view.window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func configure(
        item: MediaItem,
        selected: Bool,
        pixelSize: Int,
        thumbnails: ThumbnailLoader,
        onToggle: @escaping (_ rangeSelect: Bool) -> Void,
        onOpenLightbox: @escaping () -> Void
    ) {
        let key = item.dedupKey
        let sameItem = representedKey == key
        representedKey = key
        self.onToggle = onToggle
        self.onOpenLightbox = onOpenLightbox
        setSelectedAppearance(selected)

        // reconfiguring a cell that already shows this photo must not blank it for
        // the async reload: that made the grid flicker on every update
        loadTask?.cancel()
        if sameItem, shownPixelSize == pixelSize { return }
        guard let base = item.thumb else {
            show(nil, pixelSize: nil)
            return
        }
        if let cached = thumbnails.cachedThumbnail(pixelSize: pixelSize, cacheKey: key) {
            show(cached, pixelSize: pixelSize)
            return
        }
        // a resize keeps the old resolution up until the new one arrives
        if !sameItem { show(nil, pixelSize: nil) }
        loadTask = Task { [weak self] in
            guard let image = try? await thumbnails.thumbnail(base: base, pixelSize: pixelSize, cacheKey: key) else {
                return
            }
            guard let self, !Task.isCancelled, self.representedKey == key else { return }
            self.show(image, pixelSize: pixelSize)
        }
    }

    private func show(_ image: CGImage?, pixelSize: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        shownPixelSize = pixelSize
    }

    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    private static let selectedImage = NSImage(
        systemSymbolName: "checkmark.circle.fill",
        accessibilityDescription: String(localized: "Selected")
    )?.withSymbolConfiguration(symbolConfiguration)
    private static let unselectedImage = NSImage(
        systemSymbolName: "circle",
        accessibilityDescription: String(localized: "Not selected")
    )?.withSymbolConfiguration(symbolConfiguration)

    func setSelectedAppearance(_ selected: Bool) {
        dimLayer.isHidden = !selected
        checkView.image = selected ? Self.selectedImage : Self.unselectedImage
        checkView.contentTintColor = selected ? .controlAccentColor : .white
        checkView.layer?.shadowOpacity = selected ? 0 : 0.6
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedKey = nil
        show(nil, pixelSize: nil)
        dimLayer.isHidden = true
    }

    @objc private func openLightbox() {
        onOpenLightbox?()
    }
}

// Click anywhere toggles; only the magnifier keeps its own click handling. The
// checkbox image view is an NSControl that would otherwise swallow the main
// affordance's clicks, so hit-testing funnels everything else to this view.
private final class PhotoCellClickView: NSView {
    var onClick: ((_ rangeSelect: Bool) -> Void)?
    weak var magnifier: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let magnifier, hit === magnifier || hit.isDescendant(of: magnifier) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.shift))
    }
}

final class PhotoSectionHeaderView: NSVisualEffectView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoSectionHeaderView")

    var title: String = "" {
        didSet { label.stringValue = title }
    }
    var onSelectAll: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let selectButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .headerView
        blendingMode = .withinWindow
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.title = String(localized: "Select")
        selectButton.bezelStyle = .glass
        selectButton.controlSize = .small
        selectButton.toolTip = String(localized: "Select every photo in this group")
        selectButton.target = self
        selectButton.action = #selector(selectGroup)
        addSubview(selectButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: selectButton.leadingAnchor, constant: -8),
            selectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            selectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func prepareForReuse() {
        onSelectAll = nil
    }

    @objc private func selectGroup() {
        onSelectAll?()
    }
}
