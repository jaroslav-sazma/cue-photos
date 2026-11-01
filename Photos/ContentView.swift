import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            // The web view stays mounted in every state, and never at opacity 0:
            // WebKit treats a fully transparent view as a hidden page and throttles
            // its DOM timers, which stalls gptk's retry backoff mid-RPC
            WebView(model.runtime.page)
                .opacity(model.runtime.state == .needsLogin ? 1 : 0.02)
                .allowsHitTesting(model.runtime.state == .needsLogin)

            // opaque shield: the faint web view must never shine through translucent
            // parts of the native UI (it stays technically visible to WebKit behind it)
            if model.runtime.state != .needsLogin {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .ignoresSafeArea()
            }

            switch model.runtime.state {
            case .starting:
                ProgressView("Connecting to Google Photos…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            case .needsLogin:
                EmptyView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Connection failed", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { model.runtime.load() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            case .ready:
                ConnectedView()
            }

            LightboxView()
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { model.runtime.start() }
    }
}

private struct ConnectedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var downloads = model.downloads
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                .overlay {
                    // a transient refresh failure must not cover a list that is
                    // still perfectly usable
                    if case .failed(let message) = model.albumsStore.phase,
                       model.albumsStore.albums.isEmpty {
                        ContentUnavailableView {
                            Label("Couldn't load albums", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Retry") { Task { await model.refreshAll() } }
                        }
                    }
                }
        } detail: {
            BrowserView()
        }
        .navigationTitle("Cue: Pick & Place")
        .sheet(isPresented: $model.addToAlbumSheetShown) {
            AddToAlbumSheet()
        }
        .confirmationDialog(
            "Move \(model.selection.count) photos to the trash?",
            isPresented: $model.trashConfirmationShown
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashSelection() }
            }
        } message: {
            Text("Google Photos keeps trashed items for 60 days.")
        }
        .confirmationDialog(
            "Remove \(model.removableFromCurrentAlbum.count) photos from this album?",
            isPresented: $model.removeFromAlbumConfirmationShown
        ) {
            Button("Remove from Album", role: .destructive) {
                Task { await model.removeSelectionFromAlbum() }
            }
        } message: {
            Text("The photos stay in your library and in any other albums.")
        }
        .fileImporter(
            isPresented: $downloads.folderPickerShown,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let folder = urls.first {
                model.startDownload(folder: folder)
            }
        }
        .sheet(isPresented: $model.aboutShown) {
            AboutView()
        }
        .sheet(item: $model.renameTarget) { album in
            RenameAlbumSheet(album: album)
        }
        .task { await model.bootstrap() }
    }
}
