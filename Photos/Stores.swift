import Foundation
import Observation
import os

private nonisolated let storesLog = Logger(subsystem: "app.cue.photos", category: "stores")

@Observable
final class AlbumsStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var albums: [Album] = []
    private(set) var revision = 0
    private var generation = 0

    func refresh(using service: PhotosService) async {
        generation += 1
        let current = generation
        phase = .loading
        do {
            let result = try await service.albums()
            guard current == generation else { return }
            albums = result
            revision += 1
            phase = .ready
        } catch is CancellationError {
            if current == generation { phase = .idle }
        } catch {
            guard current == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        generation += 1
        albums = []
        revision += 1
        phase = .idle
    }
}

// Holds the whole timeline in memory (~300–500 B/item, 50k ≈ 20 MB): sorting, grouping
// and filtering then happen locally and instantly. The first load publishes page by
// page; a refresh keeps the old items until the new load completes.
@Observable
final class LibraryStore {
    enum Phase: Equatable {
        case idle
        case loading(loadedCount: Int)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [MediaItem] = []
    private(set) var revision = 0
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    func refresh(using service: PhotosService) {
        generation += 1
        let current = generation
        loadTask?.cancel()
        phase = .loading(loadedCount: 0)
        loadTask = Task { await load(using: service, generation: current) }
    }

    func reset() {
        generation += 1
        loadTask?.cancel()
        items = []
        revision += 1
        phase = .idle
    }

    // local prune after a successful trash action; Google already removed them
    func removeItems(dedupKeys: Set<String>) {
        guard !dedupKeys.isEmpty else { return }
        items.removeAll { dedupKeys.contains($0.dedupKey) }
        revision += 1
    }

    private func load(using service: PhotosService, generation current: Int) async {
        let progressive = items.isEmpty
        var loaded: [MediaItem] = []
        do {
            var pageId: String?
            var fromTimestamp: Double?
            var pages = 0
            repeat {
                let page = try await service.libraryPage(fromTimestamp: fromTimestamp, pageId: pageId)
                guard current == generation, !Task.isCancelled else { return }
                loaded.append(contentsOf: page.items)
                if progressive {
                    items = loaded
                    revision += 1
                }
                phase = .loading(loadedCount: loaded.count)
                guard page.nextPageId != pageId else { break }
                pageId = page.nextPageId
                pages += 1
                // gptk pages the timeline by walking lastItemTimestamp - 1 alongside the page id
                fromTimestamp = page.lastItemTimestamp.map { $0 - 1 }
            } while pageId != nil && pages < 10_000
            guard current == generation else { return }
            items = loaded
            revision += 1
            phase = .ready
        } catch is CancellationError {
        } catch {
            guard current == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

// Backs the "outside any album" filter: the union of dedupKeys across all album pages,
// built right after login at utility priority through the shared RPC limiter. Once
// ready it stays ready during rebuilds (the old set keeps serving the filter);
// `progress` reports any build underway.
@Observable
final class AlbumMembershipIndex {
    enum Phase: Equatable {
        case idle
        case building
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: (done: Int, total: Int)?
    private(set) var dedupKeysInAlbums: Set<String> = []
    private(set) var revision = 0
    // per-album sets so a removal from one album can tell whether a photo still
    // lives elsewhere, without re-reading every album from the network
    private var keysByAlbum: [String: Set<String>] = [:]
    private var generation = 0
    private var buildTask: Task<Void, Never>?

    func rebuild(albums: [Album], using service: PhotosService) {
        generation += 1
        let current = generation
        buildTask?.cancel()
        if phase != .ready { phase = .building }
        progress = (0, albums.count)
        buildTask = Task(priority: .utility) { await build(albums: albums, using: service, generation: current) }
    }

    func reset() {
        generation += 1
        buildTask?.cancel()
        dedupKeysInAlbums = []
        keysByAlbum = [:]
        revision += 1
        progress = nil
        phase = .idle
    }

    // local updates after confirmed writes keep the outside-any-album filter honest
    // without a full rebuild
    func insert(dedupKeys: some Sequence<String>, albumKey: String) {
        keysByAlbum[albumKey, default: []].formUnion(dedupKeys)
        dedupKeysInAlbums.formUnion(dedupKeys)
        revision += 1
    }

    // a trashed photo leaves every album
    func remove(dedupKeys: Set<String>) {
        for key in keysByAlbum.keys {
            keysByAlbum[key]?.subtract(dedupKeys)
        }
        dedupKeysInAlbums.subtract(dedupKeys)
        revision += 1
    }

    // removal from one album: a photo leaves the index only when no other album
    // still contains it
    func remove(dedupKeys: Set<String>, fromAlbum albumKey: String) {
        keysByAlbum[albumKey]?.subtract(dedupKeys)
        let stillElsewhere = dedupKeys.filter { key in
            keysByAlbum.contains { $0.key != albumKey && $0.value.contains(key) }
        }
        dedupKeysInAlbums.subtract(dedupKeys.subtracting(stillElsewhere))
        revision += 1
    }

    private func build(albums: [Album], using service: PhotosService, generation current: Int) async {
        // a cancelled build must never leave a stale progress pill; a newer build
        // (different generation) owns the progress by then
        defer {
            if current == generation {
                progress = nil
            }
        }
        storesLog.log("membership build started: \(albums.count) albums")
        var collected = Set<String>()
        var byAlbum: [String: Set<String>] = [:]
        var done = 0
        do {
            for album in albums {
                var albumKeys = Set<String>()
                var pageId: String?
                var pages = 0
                repeat {
                    let page = try await service.albumItemsPage(album, pageId: pageId)
                    guard current == generation, !Task.isCancelled else { return }
                    for item in page.items {
                        albumKeys.insert(item.dedupKey)
                    }
                    storesLog.info("membership album \(done + 1)/\(albums.count): page \(pages + 1), \(page.items.count) items, more=\(page.nextPageId != nil)")
                    guard page.nextPageId != pageId else { break }
                    pageId = page.nextPageId
                    pages += 1
                } while pageId != nil && pages < 10_000
                collected.formUnion(albumKeys)
                byAlbum[album.mediaKey] = albumKeys
                done += 1
                progress = (done, albums.count)
            }
            guard current == generation else { return }
            dedupKeysInAlbums = collected
            keysByAlbum = byAlbum
            revision += 1
            phase = .ready
            storesLog.log("membership build finished: \(collected.count) keys")
        } catch is CancellationError {
            storesLog.log("membership build cancelled at \(done)/\(albums.count)")
        } catch {
            guard current == generation else { return }
            if phase != .ready { phase = .failed(error.localizedDescription) }
            storesLog.error("membership build failed: \(error.localizedDescription)")
        }
    }
}

@Observable
final class TrashStore {
    enum Phase: Equatable {
        case idle
        case loading(loadedCount: Int)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [MediaItem] = []
    private(set) var revision = 0
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    func refresh(using service: PhotosService) {
        generation += 1
        let current = generation
        loadTask?.cancel()
        phase = .loading(loadedCount: 0)
        loadTask = Task { await load(using: service, generation: current) }
    }

    func reset() {
        generation += 1
        loadTask?.cancel()
        items = []
        revision += 1
        phase = .idle
    }


    // local prune after a successful trash action; Google already removed them
    func removeItems(dedupKeys: Set<String>) {
        guard !dedupKeys.isEmpty else { return }
        items.removeAll { dedupKeys.contains($0.dedupKey) }
        revision += 1
    }

    private func load(using service: PhotosService, generation current: Int) async {
        var loaded: [MediaItem] = []
        do {
            var pageId: String?
            var pages = 0
            repeat {
                let page = try await service.trashPage(pageId: pageId)
                guard current == generation, !Task.isCancelled else { return }
                loaded.append(contentsOf: page.items)
                phase = .loading(loadedCount: loaded.count)
                guard page.nextPageId != pageId else { break }
                pageId = page.nextPageId
                pages += 1
            } while pageId != nil && pages < 10_000
            guard current == generation else { return }
            items = loaded
            revision += 1
            phase = .ready
        } catch is CancellationError {
        } catch {
            guard current == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

@Observable
final class AlbumContentsStore {
    enum Phase: Equatable {
        case idle
        case loading(loadedCount: Int)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var albumKey: String?
    // the album key as the server reports it on the album's own pages: for shared
    // albums that is the share token, which LjmOue requires
    private(set) var serverAlbumKey: String?
    private(set) var items: [MediaItem] = []
    private(set) var revision = 0
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    func refresh(album: Album, using service: PhotosService) {
        generation += 1
        let current = generation
        loadTask?.cancel()
        albumKey = album.mediaKey
        serverAlbumKey = nil
        items = []
        removedKeys = []
        revision += 1
        phase = .loading(loadedCount: 0)
        loadTask = Task { await load(album: album, using: service, generation: current) }
    }

    func reset() {
        generation += 1
        loadTask?.cancel()
        albumKey = nil
        serverAlbumKey = nil
        items = []
        removedKeys = []
        revision += 1
        phase = .idle
    }

    // keys pruned mid-load must not come back when later pages land
    private var removedKeys = Set<String>()

    // local prune after a successful trash or remove-from-album action; Google
    // already removed them
    func removeItems(dedupKeys: Set<String>) {
        guard !dedupKeys.isEmpty else { return }
        items.removeAll { dedupKeys.contains($0.dedupKey) }
        removedKeys.formUnion(dedupKeys)
        revision += 1
    }

    private func load(album: Album, using service: PhotosService, generation current: Int) async {
        var loaded: [MediaItem] = []
        var seen = Set<String>()
        do {
            var pageId: String?
            var pages = 0
            repeat {
                let page = try await service.albumItemsPage(album, pageId: pageId)
                guard current == generation, !Task.isCancelled else { return }
                if serverAlbumKey == nil { serverAlbumKey = page.mediaKey }
                // pages can overlap; the grid hides duplicates when sectioning,
                // but bulk actions must not process a photo twice
                loaded.append(contentsOf: page.items.filter { seen.insert($0.dedupKey).inserted })
                if !removedKeys.isEmpty {
                    loaded.removeAll { removedKeys.contains($0.dedupKey) }
                }
                items = loaded
                revision += 1
                phase = .loading(loadedCount: loaded.count)
                guard page.nextPageId != pageId else { break }
                pageId = page.nextPageId
                pages += 1
            } while pageId != nil && pages < 10_000
            guard current == generation else { return }
            if !removedKeys.isEmpty {
                loaded.removeAll { removedKeys.contains($0.dedupKey) }
            }
            items = loaded
            revision += 1
            phase = .ready
        } catch is CancellationError {
        } catch {
            guard current == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
