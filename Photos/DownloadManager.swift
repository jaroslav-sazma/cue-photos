import AppKit
import Foundation
import Observation
import os

// Downloads originals of the selection into a user-picked folder. Holds a sleep
// assertion while running (the one background exception the hard rules allow) and
// releases it the moment the run ends. Each finished file leaves the selection, so an
// interrupted run keeps exactly the unfinished photos selected.
@Observable
final class DownloadManager {
    enum Phase: Equatable {
        case idle
        case running
    }

    var folderPickerShown = false
    private(set) var phase: Phase = .idle
    private(set) var progress: (done: Int, total: Int)?
    private(set) var currentFileName: String?

    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private let log = Logger(subsystem: "app.cue.photos", category: "downloads")

    var isActive: Bool { phase == .running }

    var percent: Int {
        guard let progress, progress.total > 0 else { return 0 }
        return Int((Double(progress.done) / Double(progress.total) * 100).rounded())
    }

    func beginFolderPick() {
        guard !isActive else { return }
        folderPickerShown = true
    }

    func cancel() {
        task?.cancel()
    }

    func start(
        items: [MediaItem],
        folder: URL,
        service: PhotosService,
        session: GoogleSession,
        selection: SelectionStore,
        onFinished: @escaping (String) -> Void
    ) {
        guard !isActive, !items.isEmpty else { return }
        phase = .running
        progress = (0, items.count)
        currentFileName = nil
        task = Task {
            await run(
                items: items, folder: folder, service: service,
                session: session, selection: selection, onFinished: onFinished
            )
        }
    }

    private func run(
        items: [MediaItem],
        folder: URL,
        service: PhotosService,
        session: GoogleSession,
        selection: SelectionStore,
        onFinished: @escaping (String) -> Void
    ) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Downloading originals from Google Photos"
        )
        defer {
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
            }
            activity = nil
            if scoped {
                folder.stopAccessingSecurityScopedResource()
            }
            phase = .idle
            progress = nil
            currentFileName = nil
        }

        var names: [String: String] = [:]
        do {
            let infos = try await service.batchMediaInfo(mediaKeys: items.map(\.mediaKey))
            names = Dictionary(
                infos.compactMap { info in info.mediaKey.flatMap { key in info.fileName.map { (key, $0) } } },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            log.warning("file names unavailable, falling back to keys: \(error.localizedDescription)")
        }

        var done = 0
        var failed = 0
        var folderUnwritable = false
        for item in items {
            if Task.isCancelled { break }
            let preferredName = names[item.mediaKey]
            currentFileName = preferredName
            do {
                try await downloadOne(item, preferredName: preferredName, folder: folder, session: session)
                selection.removeCompleted([item.dedupKey])
                done += 1
            } catch is CancellationError {
                break
            } catch {
                failed += 1
                log.error("download failed: \(error.localizedDescription)")
                if (error as? CocoaError)?.code == .fileWriteNoPermission {
                    // every further file would fail the same way
                    folderUnwritable = true
                    break
                }
            }
            progress = (done + failed, items.count)
        }

        let summary: String
        if folderUnwritable {
            summary = String(localized: "The folder is not writable — \(done) files saved, the rest stayed selected")
        } else if Task.isCancelled {
            summary = String(localized: "Download cancelled — \(done) files saved, the rest stayed selected")
        } else if failed == 0 {
            summary = String(localized: "Downloaded \(done) files")
        } else {
            summary = String(localized: "Downloaded \(done) files; \(failed) failed and stayed selected")
        }
        onFinished(summary)
    }

    private func downloadOne(
        _ item: MediaItem,
        preferredName: String?,
        folder: URL,
        session: GoogleSession
    ) async throws {
        guard let base = item.thumb else {
            throw PhotosError.mediaFetch("item has no media URL")
        }
        // =d serves the original photo bytes, =dv the (transcoded) video — the same
        // parameters the Google Photos web app itself downloads with
        let suffix = item.duration != nil ? "=dv" : "=d"
        guard let url = URL(string: base + suffix) else {
            throw PhotosError.mediaFetch("invalid media URL")
        }
        let (tempURL, response) = try await session.download(from: url)
        guard response.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw PhotosError.mediaFetch("HTTP \(response.statusCode)")
        }
        // a video must never silently land as a still frame and leave the selection
        if item.duration != nil, response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image") == true {
            try? FileManager.default.removeItem(at: tempURL)
            throw PhotosError.mediaFetch("expected a video, got an image response")
        }
        let fallback = "photo-\(item.dedupKey.prefix(12))" + (item.duration != nil ? ".mp4" : ".jpg")
        let name = preferredName
            ?? response.suggestedFilename
            ?? fallback
        try await Self.store(tempURL: tempURL, folder: folder, name: name)
    }

    // off the main actor: a cross-volume move copies the whole file
    @concurrent
    private nonisolated static func store(tempURL: URL, folder: URL, name: String) async throws {
        let target = collisionFreeURL(folder: folder, name: sanitized(name))
        do {
            try FileManager.default.moveItem(at: tempURL, to: target)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // server-supplied names: strip separators and control characters, no hidden
    // files, keep the extension while capping the length the filesystem accepts
    private nonisolated static func sanitized(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && !CharacterSet.controlCharacters.contains(scalar)
        })
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty {
            cleaned = "photo"
        }
        let ext = (cleaned as NSString).pathExtension
        var base = (cleaned as NSString).deletingPathExtension
        while (base + "." + ext).utf8.count > 200, !base.isEmpty {
            base = String(base.dropLast())
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private nonisolated static func collisionFreeURL(folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appending(path: numbered)
            counter += 1
        }
        return candidate
    }
}
