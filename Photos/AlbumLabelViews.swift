import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AlbumLabelMenu: View {
    @Binding var title: String

    @Environment(AppModel.self) private var model
    @State private var editorShown = false

    var body: some View {
        let labels = model.labels.labels
        let current = labels.label(of: title)
        Menu {
            Picker("Label", selection: Binding(
                get: { current?.id },
                set: { id in title = labels.applying(model.labels.label(id: id), to: title) }
            )) {
                Text("No label").tag(String?.none)
                ForEach(labels) { label in
                    Text(verbatim: "\(label.emoji)  \(label.name)").tag(Optional(label.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Edit Labels…") {
                editorShown = true
            }
        } label: {
            if let current {
                Text(current.emoji)
            } else {
                Image(systemName: "tag")
            }
        }
        .fixedSize()
        .help(current?.name ?? String(localized: "Album label"))
        .sheet(isPresented: $editorShown) {
            AlbumLabelsSheet()
        }
    }
}

struct AlbumLabelFilter: View {
    @Binding var selection: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        let labels = model.labels.labels
        if !labels.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(labels) { label in
                        Toggle(isOn: Binding(
                            get: { selection == label.id },
                            set: { selection = $0 ? label.id : nil }
                        )) {
                            Text(label.emoji)
                        }
                        .toggleStyle(.button)
                        .help(label.name)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

struct AlbumLabelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newEmoji = ""
    @State private var newName = ""
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var importerShown = false
    @State private var exportDocument: AlbumLabelsDocument?
    @FocusState private var emojiFocused: Bool

    private var store: AlbumLabelStore { model.labels }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Album Labels")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            Text("A label is an emoji at the start of an album name. Pick it when you create or rename an album, then filter your albums by it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(store.labels) { label in
                    HStack(spacing: 10) {
                        Text(label.emoji)
                            .font(.title3)
                            .frame(width: 28)
                        TextField("Name", text: Binding(
                            get: { label.name },
                            set: { store.rename(id: label.id, to: $0) }
                        ))
                        .textFieldStyle(.plain)
                        Button {
                            store.remove(id: label.id)
                        } label: {
                            Label("Delete label", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Delete label")
                    }
                }
            }
            .frame(minHeight: 180)
            .overlay {
                if store.labels.isEmpty {
                    ContentUnavailableView("No labels yet", systemImage: "tag")
                }
            }

            HStack {
                TextField("Emoji", text: $newEmoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .focused($emojiFocused)
                Button {
                    emojiFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Label("Choose emoji", systemImage: "face.smiling")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Choose emoji")
                TextField("Name, e.g. Vacation", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") {
                    add()
                }
                .disabled(newEmoji.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let infoText {
                Text(infoText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Deleting a label leaves album names as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Import…") {
                    importerShown = true
                }
                Button("Export…") {
                    export()
                }
                .disabled(store.labels.isEmpty)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 420)
        .fileImporter(isPresented: $importerShown, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                importLabels(from: url)
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .json,
            defaultFilename: String(localized: "Cue Photos Labels")
        ) { result in
            if case .failure(let error) = result {
                errorText = error.localizedDescription
            }
        }
    }

    private func add() {
        let emoji = newEmoji.trimmingCharacters(in: .whitespaces)
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard AlbumLabel.isValidEmoji(emoji) else {
            errorText = String(localized: "Enter a single emoji.")
            return
        }
        guard !name.isEmpty else {
            errorText = String(localized: "Enter a name for the label.")
            return
        }
        guard store.add(AlbumLabel(emoji: emoji, name: name)) else {
            errorText = String(localized: "This emoji already has a label.")
            return
        }
        errorText = nil
        newEmoji = ""
        newName = ""
    }

    private func export() {
        do {
            exportDocument = AlbumLabelsDocument(data: try store.exportData())
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importLabels(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let changed = try store.importData(try Data(contentsOf: url))
            errorText = nil
            infoText = String(localized: "Imported \(changed) labels")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

nonisolated struct AlbumLabelsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
