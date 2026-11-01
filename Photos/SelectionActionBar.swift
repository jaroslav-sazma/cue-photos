import SwiftUI

// Floating glass bar, visible on every screen whenever the selection is non-empty
struct SelectionActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selection.isEmpty {
            undoPill
        } else {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 18) {
            Button {
                model.ui.destination = .selection
            } label: {
                Text("\(model.selection.count) selected")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("Show the selected photos")

            Button("Deselect") {
                model.clearSelectionWithUndo()
            }
            .buttonStyle(.plain)
            .font(.body)
            .foregroundStyle(.secondary)

            Divider()
                .frame(height: 24)

            if model.isBulkWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                model.beginDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .help("Download originals to a folder")

            if model.ui.destination == .trash {
                Button {
                    Task { await model.restoreSelectionFromTrash() }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward.circle")
                }
                .help("Restore the selected photos from the trash")
            } else {
                Button {
                    model.beginAddToAlbum()
                } label: {
                    Label("Add to album", systemImage: "rectangle.stack.badge.plus")
                }
                .help("Add the selection to an album")

                if case .album = model.ui.destination {
                    Button {
                        model.confirmRemoveFromAlbum()
                    } label: {
                        Label("Remove from album", systemImage: "rectangle.stack.badge.minus")
                    }
                    .help("Remove the selected photos from this album")
                    .disabled(!model.hasRemovableSelection)
                }

                Button(role: .destructive) {
                    model.confirmTrash()
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .help("Move the selection to the trash")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title2)
        .disabled(model.isBulkWorking || model.downloads.isActive)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private var undoPill: some View {
        if !model.lastClearedSelection.isEmpty {
            HStack(spacing: 10) {
                Text("Selection cleared")
                    .foregroundStyle(.secondary)
                Button("Undo") {
                    model.undoClearSelection()
                }
                .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }
}
