import CryptoKit
import Foundation
import Observation
import WebKit

@Observable
final class AppModel {
    let runtime: WebRuntime
    let photos: PhotosService
    let thumbnails: ThumbnailLoader
    let selection: SelectionStore
    let labels = AlbumLabelStore(fileURL: AlbumLabelStore.defaultFileURL())
    let albumsStore = AlbumsStore()
    let library = LibraryStore()
    let membership = AlbumMembershipIndex()
    let trash = TrashStore()
    let albumContents = AlbumContentsStore()
    let ui = BrowseState()

    // undo buffer for an explicit "clear selection"
    var lastClearedSelection: [SelectionStore.Entry] = []
    // shift-click range anchor, scoped to whatever view the user last clicked in
    var lastToggledKey: String?

    private var bootstrapped = false
    private static let lastAccountKey = "lastAccountHash"

    private let googleSession: GoogleSession

    init() {
        let runtime = WebRuntime()
        self.runtime = runtime
        self.photos = PhotosService(runtime: runtime)
        let session = GoogleSession(runtime: runtime)
        self.googleSession = session
        self.thumbnails = ThumbnailLoader(session: session)
        self.selection = SelectionStore(fileURL: SelectionStore.defaultFileURL())
    }

    func bootstrap() async {
        handleAccountChange()
        guard !bootstrapped else { return }
        await refreshAll()
    }

    func refreshAll() async {
        handleAccountChange()
        await albumsStore.refresh(using: photos)
        guard albumsStore.phase == .ready else { return }
        // bootstrapped flips only after the album list truly loaded: the membership
        // index must never build from an empty-because-failed album list
        bootstrapped = true
        library.refresh(using: photos)
        membership.rebuild(albums: albumsStore.albums, using: photos)
    }

    // Owner decision 2026-10-31: a different Google account discards all per-account
    // state. Only a per-install-salted SHA256 of the account id is stored locally.
    private func handleAccountChange() {
        guard let account = runtime.accountID else { return }
        let defaults = UserDefaults.standard
        var salt = defaults.string(forKey: "accountHashSalt")
        if salt == nil {
            salt = UUID().uuidString
            defaults.set(salt, forKey: "accountHashSalt")
        }
        let hash = SHA256.hash(data: Data(((salt ?? "") + account).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: Self.lastAccountKey)
        if let previous, previous != hash {
            selection.clear()
            selection.saveNow()
            lastClearedSelection = []
            lastToggledKey = nil
            lightbox = nil
            map = nil
            ui.destination = .library
            albumsStore.reset()
            library.reset()
            membership.reset()
            trash.reset()
            albumContents.reset()
            bootstrapped = false
            let loader = thumbnails
            let session = googleSession
            Task {
                await loader.clearCache()
                await session.invalidate()
            }
        }
        defaults.set(hash, forKey: Self.lastAccountKey)
    }

    var sortedFilteredAlbums: [Album] {
        albumsStore.sorted(by: ui.albumSort)
            .filtered(search: ui.albumSearch, label: labels.label(id: ui.albumLabelFilter))
    }

    func selectionItems() -> [MediaItem] {
        SelectionStore.items(for: selection.sortedEntries, preferring: library.items)
    }

    private var undoExpiryTask: Task<Void, Never>?

    func clearSelectionWithUndo() {
        lastClearedSelection = selection.clear()
        undoExpiryTask?.cancel()
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.lastClearedSelection = []
        }
    }

    func undoClearSelection() {
        undoExpiryTask?.cancel()
        selection.restore(lastClearedSelection)
        lastClearedSelection = []
    }

    // MARK: lightbox

    nonisolated struct LightboxState {
        var items: PhotoGrid
        var index: Int
        var album: Album?

        var current: MediaItem { items[index] }
    }

    var lightbox: LightboxState?

    func openLightbox(at index: Int, in grid: PhotoGrid, album: Album?) {
        guard grid.indices.contains(index) else { return }
        lightbox = LightboxState(items: grid, index: index, album: album)
    }

    // MARK: map

    nonisolated struct MapState: Identifiable {
        let id = UUID()
        var title: String
        var items: PhotoGrid
        var album: Album?
        var borrowsLibraryLocations: Bool
    }

    var map: MapState?

    func openMap(title: String, grid: PhotoGrid, album: Album?) {
        map = MapState(
            title: title,
            items: grid,
            album: album,
            borrowsLibraryLocations: ui.destination != .library
        )
    }

    // a spot on the map opens in the lightbox as its own little grid, so stepping stays there
    func openLightbox(positions: [Int]) {
        guard let map, !positions.isEmpty else { return }
        openLightbox(at: 0, in: map.items.subset(positions), album: map.album)
    }

    // MARK: notices

    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: bulk actions

    var addToAlbumSheetShown = false
    var trashConfirmationShown = false
    var removeFromAlbumConfirmationShown = false
    var aboutShown = false
    var labelsShown = false
    var renameTarget: Album?
    private(set) var isBulkWorking = false
    private(set) var bulkProgress: (done: Int, total: Int)?

    let downloads = DownloadManager()

    func beginDownload() {
        downloads.beginFolderPick()
    }

    func startDownload(folder: URL) {
        let items = selectionItems()
        guard !items.isEmpty else { return }
        downloads.start(
            items: items,
            folder: folder,
            service: photos,
            session: googleSession,
            selection: selection
        ) { [weak self] summary in
            self?.showNotice(summary)
        }
    }

    func beginAddToAlbum() {
        addToAlbumSheetShown = true
    }

    func confirmTrash() {
        trashConfirmationShown = true
    }

    // Snapshotted when the dialog opens: its title must not tie the whole window to
    // every album page and selection change, and the removal takes exactly the photos
    // the title counted, from the album it was asked in
    private var pendingRemoval: (albumKey: String, dedupKeys: Set<String>)?
    private(set) var pendingRemovalCount = 0

    func confirmRemoveFromAlbum() {
        guard case .album(let album) = ui.destination else { return }
        let keys = Set(removableFromCurrentAlbum.map(\.dedupKey))
        pendingRemoval = (album.mediaKey, keys)
        pendingRemovalCount = keys.count
        removeFromAlbumConfirmationShown = true
    }

    // The selection may span other albums and views; only photos actually loaded
    // in the open album can leave it. Items come from the album's pages because
    // the remove RPCs take album-scoped mediaKeys.
    var removableFromCurrentAlbum: [MediaItem] {
        guard case .album(let album) = ui.destination,
              albumContents.albumKey == album.mediaKey else { return [] }
        let entries = selection.entries
        return albumContents.items.filter { entries[$0.dedupKey] != nil }
    }

    var hasRemovableSelection: Bool {
        guard case .album(let album) = ui.destination,
              albumContents.albumKey == album.mediaKey else { return false }
        let entries = selection.entries
        return albumContents.items.contains { entries[$0.dedupKey] != nil }
    }

    func removeSelectionFromAlbum() async {
        let confirmed = pendingRemoval
        pendingRemoval = nil
        guard case .album(let album) = ui.destination, let confirmed,
              confirmed.albumKey == album.mediaKey else { return }
        let items = removableFromCurrentAlbum.filter { confirmed.dedupKeys.contains($0.dedupKey) }
        guard !items.isEmpty, !isBulkWorking, !downloads.isActive else { return }
        // the album list identifies a shared album by a key LjmOue rejects; the
        // album's own pages report the share token it requires
        var target = album
        if album.isShared == true, let serverKey = albumContents.serverAlbumKey {
            target.mediaKey = serverKey
        }
        isBulkWorking = true
        defer { isBulkWorking = false }
        let contentsKey = albumContents.albumKey
        do {
            let report = try await photos.removeFromAlbum(items, in: target) { [weak self] chunk in
                guard let self else { return }
                let done = Set(chunk)
                selection.removeCompleted(done)
                // the user may have navigated elsewhere mid-run; never prune
                // another album's grid
                if albumContents.albumKey == contentsKey {
                    albumContents.removeItems(dedupKeys: done)
                }
                membership.remove(dedupKeys: done, fromAlbum: album.mediaKey)
            }
            await albumsStore.refresh(using: photos)
            reconcileAlbumDestination()
            if report.fullySucceeded {
                showNotice(String(localized: "Removed \(report.succeeded) photos from “\(album.displayTitle)”"))
            } else {
                let reason = report.firstErrorDescription ?? String(localized: "the operation was interrupted")
                showNotice(String(
                    localized: "Removed from the album: \(photoCountText(report.succeeded)); stayed selected: \(photoCountText(report.failed)) (\(reason))"
                ))
            }
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    private func selectionAsItems() -> [MediaItem] {
        selectionItems()
    }

    nonisolated struct AddOutcome {
        var failureText: String?
        var createdAlbum: Album?
    }

    // Only verifiably processed photos leave the selection — chunk by chunk, so even
    // a crash mid-run leaves exactly the unprocessed photos selected
    func addSelection(to target: AddTarget) async -> AddOutcome {
        let items = selectionAsItems()
        guard !items.isEmpty else { return AddOutcome() }
        guard !isBulkWorking, !downloads.isActive else {
            return AddOutcome(failureText: String(localized: "Another operation is still running."))
        }
        isBulkWorking = true
        bulkProgress = (0, items.count)
        defer {
            isBulkWorking = false
            bulkProgress = nil
        }
        do {
            var createdAlbum: Album?
            let album: Album
            switch target {
            case .existing(let existing):
                album = existing
            case .new(let name):
                let key = try await photos.createAlbum(named: name)
                album = Album(mediaKey: key, title: name, isShared: false)
                createdAlbum = album
            }
            let report = try await photos.add(
                items,
                to: album,
                onProgress: { [weak self] done, total in self?.bulkProgress = (done, total) },
                onChunkSucceeded: { [weak self] keys in
                    self?.selection.removeCompleted(keys)
                    self?.membership.insert(dedupKeys: keys, albumKey: album.mediaKey)
                }
            )
            // item counts and ordering come from the server; refresh once the add ran
            Task {
                await albumsStore.refresh(using: photos)
                reconcileAlbumDestination()
            }
            if report.fullySucceeded {
                showNotice(String(localized: "Added \(report.succeeded) photos to “\(album.displayTitle)”"))
                return AddOutcome(createdAlbum: createdAlbum)
            }
            let reason = report.firstErrorDescription ?? String(localized: "the operation was interrupted")
            let message = String(
                localized: "Added \(report.succeeded) photos; \(report.failed) stayed selected because \(reason)"
            )
            if report.cancelled {
                // the sheet is usually gone after a cancel; the notice still reports
                showNotice(message)
                return AddOutcome(createdAlbum: createdAlbum)
            }
            return AddOutcome(failureText: message, createdAlbum: createdAlbum)
        } catch {
            return AddOutcome(failureText: error.localizedDescription)
        }
    }

    nonisolated enum AddTarget {
        case existing(Album)
        case new(String)
    }

    func trashSelection() async {
        let keys = selection.sortedEntries.map(\.dedupKey)
        guard !keys.isEmpty, !isBulkWorking, !downloads.isActive else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            let report = try await photos.moveToTrash(dedupKeys: keys) { [weak self] chunk in
                let done = Set(chunk)
                self?.selection.removeCompleted(done)
                self?.library.removeItems(dedupKeys: done)
                self?.albumContents.removeItems(dedupKeys: done)
                self?.membership.remove(dedupKeys: done)
            }
            // trashed photos leave their albums on Google's side; the sidebar counts
            // come from the server, so refresh them
            Task {
                await albumsStore.refresh(using: photos)
                reconcileAlbumDestination()
            }
            if report.fullySucceeded {
                showNotice(String(localized: "Moved \(report.succeeded) photos to the trash"))
            } else {
                showNotice(String(
                    localized: "Moved \(report.succeeded) photos to the trash; \(report.failed) failed and stayed selected"
                ))
            }
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    // Signs out of Google entirely: wipes the web session and all per-account state,
    // then returns to the login screen. The persisted selection stays on disk; the
    // account-change check discards it if someone else signs in.
    func signOut() async {
        guard !isBulkWorking else { return }
        downloads.cancel()
        selection.saveNow()
        lastClearedSelection = []
        lastToggledKey = nil
        lightbox = nil
        map = nil
        ui.destination = .library
        bootstrapped = false
        albumsStore.reset()
        library.reset()
        membership.reset()
        trash.reset()
        albumContents.reset()
        await thumbnails.clearCache()
        await googleSession.invalidate()
        let store = WKWebsiteDataStore.default()
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        // anything that re-synced between the two calls copied cookies that
        // removeData has since destroyed; drop them again
        await googleSession.invalidate()
        runtime.load()
    }

    // Returns nil on success, otherwise the message the rename sheet shows. The
    // fresh album list is the ground truth: Google can silently ignore a rename.
    func renameAlbum(_ album: Album, to newTitle: String) async -> String? {
        do {
            try await photos.renameAlbum(album, to: newTitle)
            await albumsStore.refresh(using: photos)
            let applied = albumsStore.albums
                .first { $0.mediaKey == album.mediaKey }?.title == newTitle
            guard applied else {
                return String(localized: "Google did not apply the rename.")
            }
            reconcileAlbumDestination()
            showNotice(String(localized: "Album renamed to “\(newTitle)”"))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // Returns nil on success, otherwise the message the edit sheet shows.
    func shareAlbum(_ album: Album, with emails: [String]) async -> String? {
        do {
            try await photos.shareAlbum(album, with: emails)
            await albumsStore.refresh(using: photos)
            reconcileAlbumDestination()
            showNotice(String(localized: "Album shared; \(emails.count) invitations sent"))
            return nil
        } catch {
            // SFKp8c can convert the album (reissuing its mediaKey) and still
            // report an error; a stale key would poison every later call
            await albumsStore.refresh(using: photos)
            reconcileAlbumDestination()
            return error.localizedDescription
        }
    }

    // Sharing or unsharing reissues an album's mediaKey on Google's side; after
    // every album-list re-read an open album must re-resolve against the fresh
    // list, or it keeps paging with a dead key. Falls back to the library when
    // the album is gone entirely.
    private func reconcileAlbumDestination() {
        guard albumsStore.phase == .ready, case .album(let current) = ui.destination else { return }
        if let byKey = albumsStore.albums.first(where: { $0.mediaKey == current.mediaKey }) {
            ui.destination = .album(byKey)
            return
        }
        // titles are not unique; a title match is only trusted when unambiguous,
        // otherwise acting on the look-alike could hit the wrong album
        let matches = albumsStore.albums.filter { $0.title == current.title }
        if current.title?.isEmpty == false, matches.count == 1, let renewed = matches.first {
            ui.destination = .album(renewed)
        } else {
            ui.destination = .library
        }
    }

    // The toolbar refresh reloads what the user sees plus the sidebar album list;
    // the full membership rebuild runs only from the library and selection views.
    func refreshDestination() async {
        switch ui.destination {
        case .library, .selection:
            await refreshAll()
        case .album(let album):
            await albumsStore.refresh(using: photos)
            reconcileAlbumDestination()
            // an unchanged key keeps the destination identity, so the view's
            // destination-keyed task won't reload the contents — do it here
            if case .album(let renewed) = ui.destination, renewed.mediaKey == album.mediaKey {
                albumContents.refresh(album: renewed, using: photos)
            }
        case .trash:
            await albumsStore.refresh(using: photos)
            trash.refresh(using: photos)
        }
    }

    func restoreSelectionFromTrash() async {
        let trashKeys = Set(trash.items.map(\.dedupKey))
        let keys = selection.sortedEntries.map(\.dedupKey).filter { trashKeys.contains($0) }
        guard !keys.isEmpty, !isBulkWorking, !downloads.isActive else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            let report = try await photos.restoreFromTrash(dedupKeys: keys) { [weak self] chunk in
                let done = Set(chunk)
                self?.selection.removeCompleted(done)
                self?.trash.removeItems(dedupKeys: done)
            }
            library.refresh(using: photos)
            // restored photos may have rejoined their albums; refresh counts and the
            // index quietly
            await albumsStore.refresh(using: photos)
            membership.rebuild(albums: albumsStore.albums, using: photos)
            if report.fullySucceeded {
                showNotice(String(localized: "Restored \(report.succeeded) photos"))
            } else {
                showNotice(String(
                    localized: "Restored \(report.succeeded) photos; \(report.failed) failed and stayed selected"
                ))
            }
        } catch {
            showNotice(error.localizedDescription)
        }
    }
}
