import SwiftUI

struct LightboxView: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        if let state = model.lightbox {
            let item = state.current
            ZStack {
                Rectangle()
                    .fill(.thinMaterial)
                    .ignoresSafeArea()

                photo(state: state, item: item)
                    .padding(.horizontal, 70)
                    .padding(.vertical, 54)

                chrome(state: state, item: item)
            }
            .task(id: item.dedupKey) { await loadImage(item) }
        }
    }

    @ViewBuilder
    private func photo(state: AppModel.LightboxState, item: MediaItem) -> some View {
        let selected = model.selection.isSelected(item.dedupKey)
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .onTapGesture {
                    model.selection.toggle(item, in: state.album)
                }
                // same affordance as the grid card, anchored to the photo itself
                .overlay(alignment: .topLeading) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selected ? Color.accentColor : .white)
                        .shadow(color: .black.opacity(0.55), radius: 2)
                        .padding(10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selection.toggle(item, in: state.album)
                        }
                }
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private func chrome(state: AppModel.LightboxState, item: MediaItem) -> some View {
        let selected = model.selection.isSelected(item.dedupKey)

        VStack {
            HStack {
                // space toggles selection without closing, matching the grid
                Button(selected ? "Deselect" : "Select") {
                    model.selection.toggle(item, in: state.album)
                }
                .keyboardShortcut(.space, modifiers: [])
                .hidden()
                .frame(width: 0, height: 0)

                Spacer()

                Button {
                    model.lightbox = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            Spacer()
            HStack {
                Text(caption(for: item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(state.index + 1) / \(state.items.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)

        HStack {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.title2)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(state.index == 0)

            Spacer()

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.title2)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(state.index >= state.items.count - 1)
        }
        .padding(.horizontal, 16)
    }

    private func step(_ delta: Int) {
        guard var state = model.lightbox else { return }
        let next = state.index + delta
        guard state.items.indices.contains(next) else { return }
        state.index = next
        model.lightbox = state
    }

    private func caption(for item: MediaItem) -> String {
        PhotoSectioner.takenDate(of: item)
            .formatted(date: .complete, time: .shortened)
    }

    private func loadImage(_ item: MediaItem) async {
        image = nil
        guard let base = item.thumb else { return }
        let loaded = try? await model.thumbnails.thumbnail(
            base: base,
            pixelSize: 2048,
            cacheKey: item.dedupKey,
            crop: false
        )
        // a slow earlier load must not overwrite a newer photo after stepping
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
