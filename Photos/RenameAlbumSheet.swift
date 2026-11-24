import SwiftUI

struct RenameAlbumSheet: View {
    let album: Album

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var savedName: String
    @State private var emailsText = ""
    @State private var errorText: String?
    @State private var isWorking = false

    init(album: Album) {
        self.album = album
        _name = State(initialValue: album.displayTitle)
        _savedName = State(initialValue: album.displayTitle)
    }

    private var canShare: Bool {
        album.isShared != true
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(canShare ? "Edit Album" : "Rename Album")
                    .font(.headline)
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    AlbumLabelMenu(title: $name)
                    TextField("Album name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                }
                HStack {
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave)
                }
            }

            if canShare {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Share Album")
                        .font(.subheadline.weight(.semibold))
                    TextField("Email addresses, separated by commas", text: $emailsText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendInvites() }
                    Text("Each address receives an email invitation to join the album.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Send Invites") {
                            sendInvites()
                        }
                        // disabled while the name has unsaved edits: inviting closes
                        // the sheet and would silently drop the rename
                        .disabled(parsedEmails().isEmpty || isWorking || canSave)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 340)
        .interactiveDismissDisabled(isWorking)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        !model.labels.labels.removingLabel(from: trimmedName).isEmpty
            && trimmedName != savedName && !isWorking
    }

    private func parsedEmails() -> [String] {
        var seen = Set<String>()
        return emailsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func save() {
        guard canSave else { return }
        errorText = nil
        isWorking = true
        Task {
            let failure = await model.renameAlbum(album, to: trimmedName)
            isWorking = false
            if let failure {
                errorText = failure
            } else if canShare {
                // the sheet stays open so a rename and an invite fit one visit
                savedName = trimmedName
            } else {
                dismiss()
            }
        }
    }

    private func sendInvites() {
        let emails = parsedEmails()
        guard !emails.isEmpty, !isWorking, !canSave else { return }
        if let invalid = emails.first(where: { !$0.isLikelyEmail }) {
            errorText = String(localized: "This doesn’t look like an email address: \(invalid)")
            return
        }
        errorText = nil
        isWorking = true
        Task {
            let failure = await model.shareAlbum(album, with: emails)
            isWorking = false
            if let failure {
                errorText = failure
            } else {
                dismiss()
            }
        }
    }
}

private extension String {
    var isLikelyEmail: Bool {
        let parts = split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".") && !contains(" ")
    }
}
