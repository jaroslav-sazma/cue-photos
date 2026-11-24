import Foundation
import Observation
import os

private nonisolated let selectionLog = Logger(subsystem: "app.cue.photos", category: "selection")

// The selection is the app's core contract: cross-album, keyed by dedupKey, persisted
// to disk so it survives navigation, relaunch and crashes. It empties only through a
// fully successful bulk action (removeCompleted) or an explicit clear (undoable).
@Observable
final class SelectionStore {
    nonisolated struct Entry: Codable, Hashable, Sendable, Identifiable {
        var dedupKey: String
        var mediaKey: String
        var albumMediaKey: String?
        var albumAuthKey: String?
        var thumb: String?
        var timestamp: Double?
        // optional for backward-compatible decoding of older selection files; video
        // identity decides between =d and =dv at download time
        var duration: Double?

        var id: String { dedupKey }

        init(item: MediaItem, album: Album?) {
            dedupKey = item.dedupKey
            mediaKey = item.mediaKey
            albumMediaKey = album?.mediaKey
            albumAuthKey = album?.authKey
            thumb = item.thumb
            timestamp = item.timestamp ?? item.creationTimestamp
            duration = item.duration
        }
    }

    private(set) var entries: [String: Entry]
    private(set) var revision = 0
    private let fileURL: URL
    private let saveDelay: Duration
    // Saves chain (each awaits the previous) and carry a generation, so writes never
    // overlap and an older snapshot can never beat a newer one to the disk
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0

    init(fileURL: URL, saveDelay: Duration = .milliseconds(300)) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        if let data = try? Data(contentsOf: fileURL) {
            if let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
                entries = stored
            } else {
                // never silently overwrite what might be a recoverable selection
                entries = [:]
                let quarantine = fileURL.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: quarantine)
                try? FileManager.default.moveItem(at: fileURL, to: quarantine)
                selectionLog.error("selection file unreadable, moved aside")
            }
        } else {
            entries = [:]
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Cue Photos/selection.json")
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    var sortedEntries: [Entry] {
        entries.values.sorted { ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
    }

    func isSelected(_ dedupKey: String) -> Bool {
        entries[dedupKey] != nil
    }

    func toggle(_ item: MediaItem, in album: Album? = nil) {
        if entries[item.dedupKey] != nil {
            entries[item.dedupKey] = nil
        } else {
            entries[item.dedupKey] = Entry(item: item, album: album)
        }
        revision += 1
        scheduleSave()
    }

    func select(_ items: [MediaItem], in album: Album? = nil) {
        for item in items where entries[item.dedupKey] == nil {
            entries[item.dedupKey] = Entry(item: item, album: album)
        }
        revision += 1
        scheduleSave()
    }

    func deselect(_ dedupKeys: some Sequence<String>) {
        for key in dedupKeys {
            entries[key] = nil
        }
        revision += 1
        scheduleSave()
    }

    @discardableResult
    func clear() -> [Entry] {
        let removed = Array(entries.values)
        entries = [:]
        revision += 1
        scheduleSave()
        return removed
    }

    func restore(_ removed: [Entry]) {
        for entry in removed {
            entries[entry.dedupKey] = entry
        }
        revision += 1
        scheduleSave()
    }

    func removeCompleted(_ dedupKeys: some Sequence<String>) {
        deselect(dedupKeys)
    }

    // For app termination: invalidates pending async saves and writes synchronously
    func saveNow() {
        saveGeneration += 1
        Self.writeSync(entries, to: fileURL)
    }

    func waitForPendingSave() async {
        await saveTask?.value
    }

    private func scheduleSave() {
        saveGeneration += 1
        let generation = saveGeneration
        saveTask?.cancel()
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            try? await Task.sleep(for: self?.saveDelay ?? .zero)
            guard let self, generation == self.saveGeneration else { return }
            await Self.write(self.entries, to: self.fileURL)
        }
    }

    @concurrent
    private nonisolated static func write(_ entries: [String: Entry], to url: URL) async {
        writeSync(entries, to: url)
    }

    private nonisolated static func writeSync(_ entries: [String: Entry], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            selectionLog.error("selection save failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

nonisolated extension SelectionStore {
    // Items for the Selection view: prefer the live library item (fresh thumb URL),
    // fall back to what the persisted entry remembers
    static func items(for entries: [Entry], preferring library: [MediaItem]) -> [MediaItem] {
        let wanted = Set(entries.map(\.dedupKey))
        var live: [String: MediaItem] = [:]
        live.reserveCapacity(wanted.count)
        for item in library where wanted.contains(item.dedupKey) && live[item.dedupKey] == nil {
            live[item.dedupKey] = item
        }
        return entries.map { live[$0.dedupKey] ?? MediaItem(from: $0) }
    }
}

extension MediaItem {
    // Rebuilds a grid-usable item from a persisted selection entry (Selection view
    // fallback when the live library item is not loaded)
    nonisolated init(from entry: SelectionStore.Entry) {
        mediaKey = entry.mediaKey
        dedupKey = entry.dedupKey
        timestamp = entry.timestamp
        creationTimestamp = entry.timestamp
        thumb = entry.thumb
        resWidth = nil
        resHeight = nil
        duration = entry.duration
        isArchived = nil
        isFavorite = nil
        isOwned = nil
    }
}
