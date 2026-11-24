import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var grid = PhotoGrid()
    @State private var assembler = GridAssembler()
    @State private var sectioningTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                NoticeToast()
                SelectionActionBar()
                DownloadBar()
            }
            .padding(.bottom, 14)
            .animation(.snappy, value: model.notice)
        }
        .toolbarVisibility(model.lightbox == nil ? .automatic : .hidden, for: .windowToolbar)
        .task(id: GridTrigger(key: gridKey, sourceRevision: sourceRevision)) { recomputeGrid() }
        .task(id: destinationKey) { await loadDestination() }
    }

    // MARK: data assembly

    private var contextAlbum: Album? {
        if case .album(let album) = model.ui.destination { return album }
        return nil
    }

    private var gridKey: GridKey {
        let isSelection = model.ui.destination == .selection
        return GridKey(
            destinationKey: destinationKey,
            sort: model.ui.sort,
            grouping: model.ui.grouping,
            scope: effectiveScope,
            range: model.ui.dateRange,
            sourceEpoch: sourceEpoch,
            membershipRevision: effectiveScope == .outsideAnyAlbum ? model.membership.revision : 0,
            selectionRevision: isSelection ? model.selection.revision : 0,
            libraryRevision: isSelection ? model.library.revision : 0
        )
    }

    // trash and selection have no append-only contract; their revision rebuilds
    private var sourceEpoch: Int {
        switch model.ui.destination {
        case .library: model.library.epoch
        case .album: model.albumContents.epoch
        case .trash: model.trash.revision
        case .selection: model.selection.revision
        }
    }

    private var sourceRevision: Int {
        switch model.ui.destination {
        case .library: model.library.revision
        case .album: model.albumContents.revision
        case .trash: model.trash.revision
        case .selection: model.selection.revision
        }
    }

    private var destinationKey: String {
        switch model.ui.destination {
        case .library: "library"
        case .album(let album): "album:\(album.mediaKey)"
        case .trash: "trash"
        case .selection: "selection"
        }
    }

    private var effectiveScope: PhotoFilterScope {
        model.ui.destination == .library ? model.ui.scope : .all
    }

    // grid assembly runs off the main actor: a large library must not stall a click
    private func recomputeGrid() {
        let key = gridKey
        let options = PhotoGridOptions(
            sort: key.sort,
            grouping: key.grouping,
            scope: key.scope,
            dedupKeysInAlbums: key.scope == .outsideAnyAlbum ? model.membership.dedupKeysInAlbums : [],
            dateRange: key.range
        )
        let source: GridSource = switch model.ui.destination {
        case .library: .items(model.library.items)
        case .album: .items(model.albumContents.items)
        case .trash: .items(model.trash.items)
        case .selection: .selection(model.selection.sortedEntries, library: model.library.items)
        }
        let assembler = assembler
        sectioningTask?.cancel()
        sectioningTask = Task {
            // a superseded call must not rebuild the actor's builder from an older list
            guard !Task.isCancelled else { return }
            let computed = await assembler.grid(from: source, options: options, key: key)
            guard let computed, !Task.isCancelled else { return }
            grid = computed
        }
    }

    private func loadDestination() async {
        switch model.ui.destination {
        case .library, .selection:
            break
        case .album(let album):
            if model.albumContents.albumKey != album.mediaKey || model.albumContents.phase == .idle {
                model.albumContents.refresh(album: album, using: model.photos)
            }
        case .trash:
            model.trash.refresh(using: model.photos)
        }
    }

    private func refreshCurrent() {
        Task { await model.refreshDestination() }
    }

    // MARK: header & content

    @ViewBuilder
    private var header: some View {
        switch model.ui.destination {
        case .library:
            EmptyView()
        case .album(let album):
            headerRow(title: album.displayTitle, subtitle: album.itemCount.map { photoCountText($0) })
        case .trash:
            headerRow(title: String(localized: "Trash"), subtitle: String(localized: "Google empties trash after 60 days"))
        case .selection:
            headerRow(title: String(localized: "Selection"), subtitle: photoCountText(model.selection.count))
        }
    }

    private func headerRow(title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Button {
                model.ui.destination = .library
            } label: {
                Image(systemName: "chevron.backward")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.glass)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if effectiveScope == .outsideAnyAlbum, model.membership.phase != .ready {
            membershipGate
        } else if grid.isEmpty {
            emptyState
        } else {
            let selection = model.selection
            PhotoGridView(
                grid: grid,
                contentIdentity: contentIdentity,
                columns: model.ui.columns,
                selectionRevision: selection.revision,
                isSelected: { selection.isSelected($0) },
                thumbnails: model.thumbnails,
                onToggle: handleToggle,
                onSelectSection: { model.selection.select($0, in: contextAlbum) },
                onOpenLightbox: { item, hint in
                    guard let index = resolve(item, hint: hint) else { return }
                    model.openLightbox(at: index, in: grid, album: contextAlbum)
                }
            )
        }
    }

    // the filter must never run against a half-built index: a photo would look
    // unsorted just because its album was not indexed yet
    @ViewBuilder
    private var membershipGate: some View {
        switch model.membership.phase {
        case .building:
            let progress = model.membership.progress ?? (0, 0)
            ContentUnavailableView {
                Label("Preparing the album index", systemImage: "square.stack.3d.up")
            } description: {
                VStack(spacing: 8) {
                    Text("Checking which photos are already in albums (\(progress.done)/\(progress.total)).")
                    ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                        .frame(maxWidth: 260)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Album index failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    model.membership.rebuild(albums: model.albumsStore.albums, using: model.photos)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.ui.destination {
        case .library where model.library.phase != .ready:
            loadingState(for: model.library.phase)
        case .album where model.albumContents.phase != .ready:
            loadingState(for: albumPhaseAsLibraryPhase)
        case .trash where model.trash.phase != .ready:
            loadingState(for: trashPhaseAsLibraryPhase)
        case .selection:
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "checkmark.circle",
                description: Text("Photos you select anywhere appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ContentUnavailableView(
                "No photos",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Nothing matches the current filters.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var albumPhaseAsLibraryPhase: LibraryStore.Phase {
        switch model.albumContents.phase {
        case .idle: .idle
        case .loading(let count): .loading(loadedCount: count)
        case .ready: .ready
        case .failed(let message): .failed(message)
        }
    }

    private var trashPhaseAsLibraryPhase: LibraryStore.Phase {
        switch model.trash.phase {
        case .idle: .idle
        case .loading(let count): .loading(loadedCount: count)
        case .ready: .ready
        case .failed(let message): .failed(message)
        }
    }

    @ViewBuilder
    private func loadingState(for phase: LibraryStore.Phase) -> some View {
        switch phase {
        case .loading(let count):
            VStack(spacing: 10) {
                ProgressView()
                if count > 0 {
                    Text("Loading photos… \(count)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading photos…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load photos", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { refreshCurrent() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var ui = model.ui
        ToolbarItemGroup {
            Menu {
                Picker("Sort", selection: $ui.sort) {
                    Text("Newest first").tag(PhotoSortOrder.newestFirst)
                    Text("Oldest first").tag(PhotoSortOrder.oldestFirst)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort order")

            ColumnsControl(columns: $ui.columns)

            Menu {
                Picker("Group by", selection: $ui.grouping) {
                    Text("Day").tag(PhotoGrouping.day)
                    Text("Month").tag(PhotoGrouping.month)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Group", systemImage: "calendar")
            }
            .help("Group photos by day or month")

            Button {
                refreshCurrent()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload from Google Photos")
        }

        ToolbarItem {
            Menu {
                Button("Album Labels…") {
                    model.labelsShown = true
                }
                Button("About Cue: Pick & Place…") {
                    model.aboutShown = true
                }
                Divider()
                Button("Sign Out", role: .destructive) {
                    Task { await model.signOut() }
                }
                .disabled(model.isBulkWorking || model.downloads.isActive)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
        }
    }

    // a change of what is shown (not a page streaming in) starts at the top
    private var contentIdentity: String {
        let range = model.ui.dateRange.map { "\($0.lowerBound.timeIntervalSince1970)-\($0.upperBound.timeIntervalSince1970)" } ?? ""
        return "\(destinationKey)|\(model.ui.sort)|\(model.ui.grouping)|\(effectiveScope)|\(range)"
    }

    // MARK: selection

    private func resolve(_ item: MediaItem, hint: Int) -> Int? {
        if grid.indices.contains(hint), grid[hint].dedupKey == item.dedupKey { return hint }
        return grid.firstIndex { $0.dedupKey == item.dedupKey }
    }

    private func handleToggle(_ item: MediaItem, hint: Int, rangeSelect: Bool) {
        if rangeSelect,
           let itemIndex = resolve(item, hint: hint),
           let anchor = model.lastToggledKey,
           let anchorIndex = grid.firstIndex(where: { $0.dedupKey == anchor }) {
            let range = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            model.selection.select(Array(grid[range]), in: contextAlbum)
        } else {
            model.selection.toggle(item, in: contextAlbum)
        }
        model.lastToggledKey = item.dedupKey
    }
}

private struct ColumnsControl: View {
    @Binding var columns: Int
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            Label("Columns", systemImage: "square.grid.3x3")
        }
        .help("Photos per row")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(columns) },
                        set: { columns = Int($0.rounded()) }
                    ),
                    in: 2...12,
                    step: 2
                )
                .frame(width: 180)
                Text("\(columns) per row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

nonisolated private struct GridKey: Equatable, Sendable {
    var destinationKey: String
    var sort: PhotoSortOrder
    var grouping: PhotoGrouping
    var scope: PhotoFilterScope
    var range: ClosedRange<Date>?
    var sourceEpoch: Int
    var membershipRevision: Int
    var selectionRevision: Int
    var libraryRevision: Int
}

// revisions, not counts: a refresh can swap 500 items for 500 different ones
nonisolated private struct GridTrigger: Equatable {
    var key: GridKey
    var sourceRevision: Int
}

nonisolated private enum GridSource: Sendable {
    case items([MediaItem])
    case selection([SelectionStore.Entry], library: [MediaItem])
}

// Owns the incremental builder off the main actor, so a streamed page extends it
// in place instead of copying its dedup set on every publish
private actor GridAssembler {
    private var builder: PhotoGridBuilder?
    private var key: GridKey?

    func grid(from source: GridSource, options: PhotoGridOptions, key: GridKey) -> PhotoGrid? {
        guard !Task.isCancelled else { return nil }
        let items = switch source {
        case .items(let items): items
        case .selection(let entries, let library): SelectionStore.items(for: entries, preferring: library)
        }
        if self.key == key, builder?.extend(to: items) == true, let grid = builder?.grid {
            return grid
        }
        builder = PhotoGridBuilder(source: items, options: options)
        self.key = key
        return builder!.grid
    }
}
