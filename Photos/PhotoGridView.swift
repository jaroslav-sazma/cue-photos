import AppKit
import SwiftUI

// NSCollectionView per the scale design: cell recycling, diffable snapshots, native
// prefetch. SwiftUI stays outside; cells are layer-backed and show a CGImage.
struct PhotoGridView: NSViewRepresentable {
    let sections: [PhotoSection]
    // bump = data behind the sections changed; cheap identity for updateNSView
    let dataRevision: Int
    let columns: Int
    let selectedKeys: Set<String>
    let thumbnails: ThumbnailLoader
    let onToggle: (MediaItem, _ rangeSelect: Bool) -> Void
    let onSelectSection: ([MediaItem]) -> Void
    let onOpenLightbox: (MediaItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = Self.makeLayout(columns: columns)
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
        context.coordinator.attach(to: collectionView)
        collectionView.prefetchDataSource = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(
            sections: sections,
            dataRevision: dataRevision,
            columns: columns,
            selectedKeys: selectedKeys
        )
    }

    private static func makeLayout(columns: Int) -> NSCollectionViewCompositionalLayout {
        NSCollectionViewCompositionalLayout { _, _ in
            let fraction = 1.0 / CGFloat(columns)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(fraction),
                    heightDimension: .fractionalHeight(1)
                )
            )
            item.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .fractionalWidth(fraction)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(32)
                ),
                elementKind: NSCollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            header.zIndex = 2
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    final class Coordinator: NSObject, NSCollectionViewPrefetching {
        var parent: PhotoGridView

        private weak var collectionView: NSCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<String, String>?
        private var itemsByKey: [String: MediaItem] = [:]
        private var titlesBySection: [String: String] = [:]
        private var appliedColumns: Int
        private var appliedRevision = Int.min
        private var appliedSectionIDs: [String] = []
        private var appliedItemIDs: [String: [String]] = [:]
        private var selectedKeys: Set<String> = []
        private var prefetchTasks: [String: Task<Void, Never>] = [:]

        init(_ parent: PhotoGridView) {
            self.parent = parent
            appliedColumns = parent.columns
        }

        func attach(to collectionView: NSCollectionView) {
            self.collectionView = collectionView
            let dataSource = NSCollectionViewDiffableDataSource<String, String>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, key in
                let cell = collectionView.makeItem(
                    withIdentifier: PhotoCellItem.identifier,
                    for: indexPath
                )
                guard let self, let cell = cell as? PhotoCellItem, let item = self.itemsByKey[key] else {
                    return cell
                }
                cell.configure(
                    item: item,
                    selected: self.selectedKeys.contains(item.dedupKey),
                    pixelSize: self.thumbnailPixelSize(),
                    thumbnails: self.parent.thumbnails,
                    onToggle: { [weak self] rangeSelect in self?.parent.onToggle(item, rangeSelect) },
                    onOpenLightbox: { [weak self] in self?.parent.onOpenLightbox(item) }
                )
                return cell
            }
            dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                let view = collectionView.makeSupplementaryView(
                    ofKind: kind,
                    withIdentifier: PhotoSectionHeaderView.identifier,
                    for: indexPath
                )
                let header = view as! PhotoSectionHeaderView
                if let self, indexPath.section < self.appliedSectionIDs.count {
                    let sectionID = self.appliedSectionIDs[indexPath.section]
                    header.title = self.titlesBySection[sectionID] ?? ""
                    // resolved at click time: a header outlives the snapshot that made it
                    header.onSelectAll = { [weak self] in self?.selectAll(inSection: sectionID) }
                }
                return header
            }
            self.dataSource = dataSource
        }

        func update(sections: [PhotoSection], dataRevision: Int, columns: Int, selectedKeys newSelection: Set<String>) {
            guard let dataSource else { return }

            let columnsChanged = columns != appliedColumns
            if columnsChanged {
                appliedColumns = columns
                collectionView?.collectionViewLayout = PhotoGridView.makeLayout(columns: columns)
            }

            if dataRevision != appliedRevision {
                appliedRevision = dataRevision
                itemsByKey = Dictionary(
                    sections.flatMap { $0.items.map { ($0.dedupKey, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
                titlesBySection = Dictionary(
                    sections.map { ($0.id, $0.title) },
                    uniquingKeysWith: { first, _ in first }
                )
                appliedSectionIDs = sections.map(\.id)
                appliedItemIDs = Dictionary(
                    sections.map { ($0.id, $0.items.map(\.dedupKey)) },
                    uniquingKeysWith: { first, _ in first }
                )
                for task in prefetchTasks.values { task.cancel() }
                prefetchTasks = [:]

                var snapshot = NSDiffableDataSourceSnapshot<String, String>()
                snapshot.appendSections(appliedSectionIDs)
                for section in sections {
                    snapshot.appendItems(section.items.map(\.dedupKey), toSection: section.id)
                }
                selectedKeys = newSelection
                // animatingDifferences: false is a reloadData in AppKit — the content
                // size collapses for a beat and the clip view yanks the scroll
                // position while pages stream in. A real diff keeps the viewport
                // still; the zero-duration group suppresses the insert animation.
                NSAnimationContext.runAnimationGroup { animation in
                    animation.duration = 0
                    animation.allowsImplicitAnimation = false
                    dataSource.apply(snapshot, animatingDifferences: true)
                }
                // same ids can carry new data (rotated thumb URLs, live items replacing
                // persisted fallbacks), so visible cells reload from itemsByKey
                reconfigureVisibleCells()
                return
            }

            if columnsChanged {
                // new size bucket: visible cells refetch at the right resolution
                reconfigureVisibleCells()
            }

            if newSelection != selectedKeys {
                let changed = newSelection.symmetricDifference(selectedKeys)
                selectedKeys = newSelection
                // push the new state straight into visible cells; off-screen cells
                // pick it up on reuse — no snapshot churn for a click
                for indexPath in collectionView?.indexPathsForVisibleItems() ?? [] {
                    guard let cell = collectionView?.item(at: indexPath) as? PhotoCellItem,
                          let key = cell.representedKey, changed.contains(key) else { continue }
                    cell.setSelectedAppearance(newSelection.contains(key))
                }
            }
        }

        private func reconfigureVisibleCells() {
            guard let collectionView else { return }
            let pixelSize = thumbnailPixelSize()
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let cell = collectionView.item(at: indexPath) as? PhotoCellItem,
                      let key = cell.representedKey, let item = itemsByKey[key] else { continue }
                cell.configure(
                    item: item,
                    selected: selectedKeys.contains(key),
                    pixelSize: pixelSize,
                    thumbnails: parent.thumbnails,
                    onToggle: { [weak self] rangeSelect in self?.parent.onToggle(item, rangeSelect) },
                    onOpenLightbox: { [weak self] in self?.parent.onOpenLightbox(item) }
                )
            }
        }

        private func thumbnailPixelSize() -> Int {
            let width = collectionView?.bounds.width ?? 1200
            let cellPoints = width / CGFloat(max(appliedColumns, 1))
            let scale = collectionView?.window?.backingScaleFactor ?? 2
            let pixels = Int(cellPoints * scale)
            // a few fixed buckets keep the thumbnail cache hit rate high
            let buckets = [128, 256, 384, 512, 768, 1024]
            return buckets.first { $0 >= pixels } ?? 1024
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let pixelSize = thumbnailPixelSize()
            let loader = parent.thumbnails
            for indexPath in indexPaths {
                guard let item = item(at: indexPath), let base = item.thumb,
                      prefetchTasks[item.dedupKey] == nil else { continue }
                let key = item.dedupKey
                prefetchTasks[key] = Task(priority: .utility) { [weak self] in
                    _ = try? await loader.thumbnail(base: base, pixelSize: pixelSize, cacheKey: key)
                    self?.prefetchTasks.removeValue(forKey: key)
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths {
                guard let item = item(at: indexPath) else { continue }
                prefetchTasks.removeValue(forKey: item.dedupKey)?.cancel()
            }
        }

        private func selectAll(inSection sectionID: String) {
            let items = (appliedItemIDs[sectionID] ?? []).compactMap { itemsByKey[$0] }
            guard !items.isEmpty else { return }
            parent.onSelectSection(items)
        }

        private func item(at indexPath: IndexPath) -> MediaItem? {
            guard indexPath.section < appliedSectionIDs.count,
                  let keys = appliedItemIDs[appliedSectionIDs[indexPath.section]],
                  indexPath.item < keys.count else { return nil }
            return itemsByKey[keys[indexPath.item]]
        }
    }
}

final class PhotoCellItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCellItem")

    private(set) var representedKey: String?
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
        representedKey = item.dedupKey
        self.onToggle = onToggle
        self.onOpenLightbox = onOpenLightbox
        setSelectedAppearance(selected)

        loadTask?.cancel()
        imageLayer.contents = nil
        guard let base = item.thumb else { return }
        let key = item.dedupKey
        loadTask = Task { [weak self] in
            guard let image = try? await thumbnails.thumbnail(base: base, pixelSize: pixelSize, cacheKey: key) else {
                return
            }
            guard let self, !Task.isCancelled, self.representedKey == key else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = image
            CATransaction.commit()
        }
    }

    func setSelectedAppearance(_ selected: Bool) {
        dimLayer.isHidden = !selected
        checkView.image = NSImage(
            systemSymbolName: selected ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: selected
                ? String(localized: "Selected") : String(localized: "Not selected")
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        checkView.contentTintColor = selected ? .controlAccentColor : .white
        checkView.layer?.shadowOpacity = selected ? 0 : 0.6
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedKey = nil
        imageLayer.contents = nil
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
