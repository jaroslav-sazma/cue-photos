import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = model.ui
        List {
            Section {
                Picker("Scope", selection: $ui.scope) {
                    Text("All").tag(PhotoFilterScope.all)
                    Text("Not in album").tag(PhotoFilterScope.outsideAnyAlbum)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.ui.destination != .library)

                if let progress = model.membership.progress {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing albums \(progress.done)/\(progress.total)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if case .failed = model.membership.phase {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                        Text("Album index failed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            model.membership.rebuild(albums: model.albumsStore.albums, using: model.photos)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }

                Toggle("Limit to date range", isOn: $ui.dateRangeEnabled)
                if ui.dateRangeEnabled {
                    DatePicker("From", selection: $ui.dateFrom, displayedComponents: .date)
                    DatePicker("To", selection: $ui.dateTo, displayedComponents: .date)
                }
            } header: {
                HStack {
                    Text("Filters")
                    Spacer()
                    Button {
                        ui.resetFilters()
                    } label: {
                        HeaderIcon(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset filters")
                }
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    TextField("Search albums", text: $ui.albumSearch)
                        .textFieldStyle(.plain)
                    if !ui.albumSearch.isEmpty {
                        Button {
                            ui.albumSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.quaternary)
                )

                AlbumLabelFilter(selection: $ui.albumLabelFilter)

                ForEach(model.sortedFilteredAlbums) { album in
                    Button {
                        model.ui.destination = .album(album)
                    } label: {
                        AlbumRow(
                            album: album,
                            isActive: isActive(album),
                            onRename: { model.renameTarget = album }
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Albums")
                    Spacer()
                    Menu {
                        Picker("Sort albums", selection: $ui.albumSort) {
                            Text("Most recent photo").tag(AlbumSortOrder.newestPhotoFirst)
                            Text("Recently created").tag(AlbumSortOrder.recentlyCreated)
                            Text("Title (A–Z)").tag(AlbumSortOrder.titleAscending)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HeaderIcon(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort albums")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        model.ui.destination = .trash
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(10)
            }
            .background(.bar)
        }
    }

    private func isActive(_ album: Album) -> Bool {
        if case .album(let current) = model.ui.destination {
            return current.mediaKey == album.mediaKey
        }
        return false
    }
}

private struct HeaderIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }
}

struct AlbumRow: View {
    let album: Album
    var isActive = false
    var onRename: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(base: album.thumb, cacheKey: album.mediaKey, side: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? .white : .primary)
                HStack(spacing: 4) {
                    if album.isShared == true {
                        Image(systemName: "person.2")
                            .imageScale(.small)
                    }
                    if let count = album.itemCount {
                        Text("\(count)")
                    }
                }
                .font(.caption)
                .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
            }
            Spacer(minLength: 0)
            if let onRename, isHovered {
                Button {
                    onRename()
                } label: {
                    // mirrors the card magnifier; a plain material circle vanishes on
                    // the light sidebar, so the backing is a solid fill with a border
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .overlay(Circle().strokeBorder(.quaternary))
                }
                .buttonStyle(.borderless)
                .help("Rename album")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor)
            }
        }
        .onHover { isHovered = $0 }
        .help(album.displayTitle)
    }
}
