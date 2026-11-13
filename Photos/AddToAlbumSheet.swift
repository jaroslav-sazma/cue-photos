import SwiftUI

struct AddToAlbumSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var labelFilter: String?
    @State private var sortOrder: AlbumSortOrder = .newestFirst
    @State private var selectedAlbumKey: String?
    @State private var newAlbumName = ""
    @State private var errorText: String?
    @State private var workTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add \(model.selection.count) photos to album")
                    .font(.headline)
                Spacer()
                Menu {
                    Picker("Sort albums", selection: $sortOrder) {
                        Text("Newest first").tag(AlbumSortOrder.newestFirst)
                        Text("Title (A–Z)").tag(AlbumSortOrder.titleAscending)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding()

            TextField("Search albums", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            AlbumLabelFilter(selection: $labelFilter)
                .padding(.horizontal)
                .padding(.top, 6)

            List(selection: $selectedAlbumKey) {
                ForEach(filteredAlbums) { album in
                    HStack {
                        AlbumRow(album: album)
                        if selectedAlbumKey == album.mediaKey {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .tag(album.mediaKey)
                }
            }
            .frame(minHeight: 260)

            Divider()

            HStack {
                AlbumLabelMenu(title: $newAlbumName)
                TextField("Or create a new album", text: $newAlbumName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            HStack {
                if model.isBulkWorking, let progress = model.bulkProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 200)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    workTask?.cancel()
                    dismiss()
                }
                Button(insertTitle) {
                    run()
                }
                .buttonStyle(.glassProminent)
                .disabled(target == nil || model.isBulkWorking || model.selection.isEmpty)
            }
            .padding()
        }
        .frame(width: 440)
        .interactiveDismissDisabled(model.isBulkWorking)
    }

    private var filteredAlbums: [Album] {
        model.albumsStore.albums
            .filtered(search: search, label: model.labels.label(id: labelFilter))
            .sorted(by: sortOrder)
    }

    private var target: AppModel.AddTarget? {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            // a bare label is not a name yet; until text follows, no album is created
            return model.labels.labels.removingLabel(from: name).isEmpty ? nil : .new(name)
        }
        if let key = selectedAlbumKey,
           let album = model.albumsStore.albums.first(where: { $0.mediaKey == key }) {
            return .existing(album)
        }
        return nil
    }

    private var insertTitle: String {
        if case .new = target {
            return String(localized: "Create & Add")
        }
        return String(localized: "Add to Album")
    }

    private func run() {
        guard let target else { return }
        errorText = nil
        workTask = Task {
            let outcome = await model.addSelection(to: target)
            if let created = outcome.createdAlbum {
                // a retry after partial failure must add to the same album, not
                // create a second one with the same name
                selectedAlbumKey = created.mediaKey
                newAlbumName = ""
            }
            if let failure = outcome.failureText {
                errorText = failure
            } else {
                dismiss()
            }
        }
    }
}
