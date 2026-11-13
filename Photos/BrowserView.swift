import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var sections: [PhotoSection] = []
    @State private var sectionsRevision = 0
    @State private var flatItems: [MediaItem] = []
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
        .task(id: sectionInputs) { recomputeSections() }
        .task(id: destinationKey) { await loadDestination() }
    }

    // MARK: data assembly

    private var contextAlbum: Album? {
        if case .album(let album) = model.ui.destination { return album }
        return nil
    }

    private var sourceItems: [MediaItem] {
        switch model.ui.destination {
        case .library: model.library.items
        case .album: model.albumContents.items
        case .trash: model.trash.items
        case .selection: model.selectionItems()
        }
    }

    // revisions, not counts: a refresh can swap 500 items for 500 different ones
    private struct SectionInputs: Equatable {
        var destinationKey: String
        var sort: PhotoSortOrder
        var grouping: PhotoGrouping
        var scope: PhotoFilterScope
        var range: ClosedRange<Date>?
        var sourceRevision: Int
        var membershipRevision: Int
        var selectionRevision: Int
        var libraryRevision: Int
    }

    private var sectionInputs: SectionInputs {
        let isSelection = model.ui.destination == .selection
        return SectionInputs(
            destinationKey: destinationKey,
            sort: model.ui.sort,
            grouping: model.ui.grouping,
            scope: effectiveScope,
            range: model.ui.dateRange,
            sourceRevision: sourceRevision,
            membershipRevision: effectiveScope == .outsideAnyAlbum ? model.membership.revision : 0,
            selectionRevision: isSelection ? model.selection.revision : 0,
            libraryRevision: isSelection ? model.library.revision : 0
        )
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

    private var sourceReady: Bool {
        switch model.ui.destination {
        case .library: model.library.phase == .ready
        case .album: model.albumContents.phase == .ready
        case .trash: model.trash.phase == .ready
        case .selection: true
        }
    }

    // sectioning runs off the main actor: 50k items must not stall a click
    private func recomputeSections() {
        let inputs = sectionInputs
        let items = sourceItems
        let membership = model.membership.dedupKeysInAlbums
        sectioningTask?.cancel()
        sectioningTask = Task {
            let computed = await Self.makeSections(items: items, inputs: inputs, membership: membership)
            guard !Task.isCancelled else { return }
            sections = computed
            sectionsRevision += 1
            flatItems = computed.flatMap(\.items)
        }
    }

    @concurrent
    private nonisolated static func makeSections(
        items: [MediaItem],
        inputs: SectionInputs,
        membership: Set<String>
    ) async -> [PhotoSection] {
        PhotoSectioner.sections(
            from: items,
            sort: inputs.sort,
            grouping: inputs.grouping,
            scope: inputs.scope,
            dedupKeysInAlbums: membership,
            dateRange: inputs.range
        )
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
        } else if sections.isEmpty {
            emptyState
        } else {
            PhotoGridView(
                sections: sections,
                dataRevision: sectionsRevision,
                columns: model.ui.columns,
                selectedKeys: Set(model.selection.entries.keys),
                thumbnails: model.thumbnails,
                onToggle: handleToggle,
                onSelectSection: { model.selection.select($0, in: contextAlbum) },
                onOpenLightbox: { model.openLightbox($0, in: flatItems, album: contextAlbum) }
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

    // MARK: selection

    private func handleToggle(_ item: MediaItem, rangeSelect: Bool) {
        if rangeSelect,
           let anchor = model.lastToggledKey,
           let anchorIndex = flatItems.firstIndex(where: { $0.dedupKey == anchor }),
           let itemIndex = flatItems.firstIndex(where: { $0.dedupKey == item.dedupKey }) {
            let range = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            model.selection.select(Array(flatItems[range]), in: contextAlbum)
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
