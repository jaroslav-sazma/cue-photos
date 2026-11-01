import Foundation
import WebKit
import os

final class PhotosService {
    // Matches gptk's operationSize preset; one chunk = one RPC
    private static let writeChunkSize = 250

    private let runtime: WebRuntime
    private let limiter = RPCLimiter()
    private let log = Logger(subsystem: "app.cue.photos", category: "photos")

    init(runtime: WebRuntime) {
        self.runtime = runtime
    }

    func albums() async throws -> [Album] {
        var all: [Album] = []
        var pageId: String?
        var pages = 0
        repeat {
            try Task.checkCancellation()
            let page: AlbumsPage = try await call("getAlbumsPage", argsJSON: "[\(try json(pageId))]") ?? AlbumsPage()
            reportDrops(page.droppedItems, in: "getAlbumsPage")
            all.append(contentsOf: page.items)
            // a server echoing the same page id back would spin forever
            guard page.nextPageId != pageId else { break }
            pageId = page.nextPageId
            pages += 1
        } while pageId != nil && pages < 10_000
        return all
    }

    func libraryPage(fromTimestamp: Double? = nil, pageId: String? = nil) async throws -> LibraryPage {
        let page: LibraryPage = try await call(
            "getLibraryPage",
            argsJSON: "[\(try json(fromTimestamp)),\(try json(pageId))]"
        ) ?? LibraryPage()
        reportDrops(page.droppedItems, in: "getLibraryPage")
        return page
    }

    func albumItemsPage(_ album: Album, pageId: String? = nil) async throws -> AlbumItemsPage {
        let page: AlbumItemsPage = try await call(
            "getAlbumItemsPage",
            argsJSON: "[\(try json(album.mediaKey)),\(try json(pageId)),\(try json(album.authKey))]"
        ) ?? AlbumItemsPage()
        reportDrops(page.droppedItems, in: "getAlbumItemsPage")
        return page
    }

    func trashPage(pageId: String? = nil) async throws -> TrashPage {
        let page: TrashPage = try await call("getTrashPage", argsJSON: "[\(try json(pageId))]") ?? TrashPage()
        reportDrops(page.droppedItems, in: "getTrashPage")
        return page
    }

    func renameAlbum(_ album: Album, to newTitle: String) async throws {
        try await callVoid(
            "renameAlbum",
            argsJSON: "[\(try json(album.mediaKey)),\(try json(newTitle)),\(try json(album.isShared))]"
        )
    }

    // deliberately absent from timeoutRetrySafe: a retry could send the invite
    // e-mails twice
    func shareAlbum(_ album: Album, with emails: [String]) async throws {
        try await callVoid("shareAlbum", argsJSON: "[\(try json(album.mediaKey)),\(try json(emails))]")
    }

    func createAlbum(named name: String) async throws -> String {
        guard let key: String = try await call("createAlbum", argsJSON: "[\(try json(name))]") else {
            throw PhotosError.badBridgeResponse
        }
        return key
    }

    func add(
        _ items: [MediaItem],
        to album: Album,
        onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil,
        onChunkSucceeded: ((_ dedupKeys: [String]) -> Void)? = nil
    ) async throws -> BulkWriteReport {
        let method = album.isShared == true ? "addItemsToSharedAlbum" : "addItemsToAlbum"
        var report = BulkWriteReport()
        let total = items.count
        let chunks = items.chunks(of: Self.writeChunkSize)
        for (index, chunk) in chunks.enumerated() {
            let dedupKeys = chunk.map(\.dedupKey)
            if Task.isCancelled {
                // unprocessed photos count as failed so the report's keys always
                // partition the input
                report.cancelled = true
                report.failedDedupKeys += chunks[index...].flatMap { $0.map(\.dedupKey) }
                break
            }
            do {
                try await callVoid(method, argsJSON: "[\(try json(chunk.map(\.mediaKey))),\(try json(album.mediaKey))]")
                report.succeededDedupKeys += dedupKeys
                onChunkSucceeded?(dedupKeys)
                onProgress?(report.succeeded + report.failed, total)
            } catch is CancellationError {
                // an interrupted RPC has an unknown outcome: keep those photos selected
                report.cancelled = true
                report.failedDedupKeys += chunks[index...].flatMap { $0.map(\.dedupKey) }
                break
            } catch {
                report.failedDedupKeys += dedupKeys
                report.firstErrorDescription = report.firstErrorDescription ?? error.localizedDescription
                onProgress?(report.succeeded + report.failed, total)
                log.error("\(method, privacy: .public): chunk of \(chunk.count) failed: \(error.localizedDescription)")
            }
        }
        return report
    }

    func add(_ items: [MediaItem], toNewAlbum name: String) async throws -> (albumMediaKey: String, report: BulkWriteReport) {
        let mediaKey = try await createAlbum(named: name)
        let album = Album(mediaKey: mediaKey, title: name, isShared: false)
        let report = try await add(items, to: album)
        return (mediaKey, report)
    }

    func removeFromAlbum(
        _ items: [MediaItem],
        in album: Album,
        onChunkSucceeded: ((_ dedupKeys: [String]) -> Void)? = nil
    ) async throws -> BulkWriteReport {
        let shared = album.isShared == true
        var report = BulkWriteReport()
        let chunks = items.chunks(of: Self.writeChunkSize)
        for (index, chunk) in chunks.enumerated() {
            let dedupKeys = chunk.map(\.dedupKey)
            if Task.isCancelled {
                report.cancelled = true
                report.failedDedupKeys += chunks[index...].flatMap { $0.map(\.dedupKey) }
                break
            }
            do {
                // the items must come from the album's own pages: the RPCs take the
                // album-scoped mediaKeys, not dedupKeys
                if shared {
                    try await callVoid(
                        "removeItemsFromSharedAlbum",
                        argsJSON: "[\(try json(album.mediaKey)),\(try json(chunk.map(\.mediaKey)))]"
                    )
                } else {
                    try await callVoid("removeItemsFromAlbum", argsJSON: "[\(try json(chunk.map(\.mediaKey)))]")
                }
                report.succeededDedupKeys += dedupKeys
                onChunkSucceeded?(dedupKeys)
            } catch is CancellationError {
                report.cancelled = true
                report.failedDedupKeys += chunks[index...].flatMap { $0.map(\.dedupKey) }
                break
            } catch {
                report.failedDedupKeys += dedupKeys
                report.firstErrorDescription = report.firstErrorDescription ?? error.localizedDescription
                log.error("removeFromAlbum: chunk of \(chunk.count) failed: \(error.localizedDescription)")
            }
        }
        return report
    }

    func moveToTrash(
        dedupKeys: [String],
        onChunkSucceeded: ((_ dedupKeys: [String]) -> Void)? = nil
    ) async throws -> BulkWriteReport {
        try await bulkByDedupKey("moveItemsToTrash", dedupKeys: dedupKeys, onChunkSucceeded: onChunkSucceeded)
    }

    func restoreFromTrash(
        dedupKeys: [String],
        onChunkSucceeded: ((_ dedupKeys: [String]) -> Void)? = nil
    ) async throws -> BulkWriteReport {
        try await bulkByDedupKey("restoreFromTrash", dedupKeys: dedupKeys, onChunkSucceeded: onChunkSucceeded)
    }

    // original file names for downloads; gptk's info RPC takes up to 5000 keys
    func batchMediaInfo(mediaKeys: [String]) async throws -> [MediaInfo] {
        var all: [MediaInfo] = []
        for chunk in mediaKeys.chunks(of: 1000) {
            try Task.checkCancellation()
            let infos: [Lenient<MediaInfo>] = try await call(
                "getBatchMediaInfo",
                argsJSON: "[\(try json(chunk))]"
            ) ?? []
            all.append(contentsOf: infos.compactMap(\.value))
        }
        return all
    }

    private func bulkByDedupKey(
        _ method: String,
        dedupKeys: [String],
        onChunkSucceeded: ((_ dedupKeys: [String]) -> Void)? = nil
    ) async throws -> BulkWriteReport {
        var report = BulkWriteReport()
        let chunks = dedupKeys.chunks(of: Self.writeChunkSize)
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled {
                report.cancelled = true
                report.failedDedupKeys += chunks[index...].flatMap(\.self)
                break
            }
            do {
                try await callVoid(method, argsJSON: "[\(try json(chunk))]")
                report.succeededDedupKeys += chunk
                onChunkSucceeded?(chunk)
            } catch is CancellationError {
                report.cancelled = true
                report.failedDedupKeys += chunks[index...].flatMap(\.self)
                break
            } catch {
                report.failedDedupKeys += chunk
                report.firstErrorDescription = report.firstErrorDescription ?? error.localizedDescription
                log.error("\(method, privacy: .public): chunk of \(chunk.count) failed: \(error.localizedDescription)")
            }
        }
        return report
    }

    // nil means the RPC succeeded with an empty payload — gptk's parser returns null
    // for empty collections, which paging callers treat as the last, empty page
    private func call<T: Decodable & Sendable>(_ method: String, argsJSON: String) async throws -> T? {
        let data = try await rawCall(method, argsJSON: argsJSON)
        let envelope: BridgeEnvelope<T> = try await Self.decodeEnvelope(data)
        try checkEnvelope(envelope, method: method)
        return envelope.value
    }

    private func callVoid(_ method: String, argsJSON: String) async throws {
        let data = try await rawCall(method, argsJSON: argsJSON)
        let envelope: BridgeEnvelope<BridgeNoValue> = try await Self.decodeEnvelope(data)
        try checkEnvelope(envelope, method: method)
    }

    @concurrent
    private nonisolated static func decodeEnvelope<T: Decodable & Sendable>(_ data: Data) async throws -> BridgeEnvelope<T> {
        try JSONDecoder().decode(BridgeEnvelope<T>.self, from: data)
    }

    private func checkEnvelope<T>(_ envelope: BridgeEnvelope<T>, method: String) throws {
        guard !envelope.ok else { return }
        if let stack = envelope.stack {
            log.error("\(method, privacy: .public) failed: \(stack, privacy: .private)")
        }
        if let diag = envelope.diag {
            log.error("bridge diag: \(String(describing: diag), privacy: .private)")
        }
        throw PhotosError.bridge(envelope.error ?? "unknown bridge error")
    }

    private func rawCall(_ method: String, argsJSON: String) async throws -> Data {
        guard runtime.state == .ready else { throw PhotosError.notReady }
        try await limiter.acquire()
        do {
            // the page can have reloaded while this call sat in the limiter queue
            guard runtime.state == .ready else { throw PhotosError.notReady }
            let data = try await performCall(method, argsJSON: argsJSON)
            await limiter.release()
            return data
        } catch {
            await limiter.release()
            throw error
        }
    }

    // a timed-out createAlbum may still have landed; retrying it could duplicate
    // the album, so only idempotent calls get the silent second attempt
    private static let timeoutRetrySafe: Set<String> = [
        "ping", "getAlbumsPage", "getLibraryPage", "getAlbumItemsPage", "getTrashPage",
        "getBatchMediaInfo", "addItemsToAlbum", "addItemsToSharedAlbum",
        "moveItemsToTrash", "restoreFromTrash", "renameAlbum", "diag",
        "removeItemsFromAlbum", "removeItemsFromSharedAlbum",
    ]

    // One silent retry after a timeout: a stalled fetch inside the page must never
    // hang the app forever (gptk's fetch has no timeout of its own)
    private func performCall(_ method: String, argsJSON: String) async throws -> Data {
        do {
            return try await singleCall(method, argsJSON: argsJSON)
        } catch PhotosError.rpcTimeout where Self.timeoutRetrySafe.contains(method) {
            log.error("rpc \(method, privacy: .public) timed out, retrying once")
            return try await singleCall(method, argsJSON: argsJSON)
        }
    }

    private func singleCall(_ method: String, argsJSON: String) async throws -> Data {
        // .info lives in the in-memory log ring only (no disk growth) and is enough
        // to catch a started-but-never-finished pair right after it happens
        log.info("rpc \(method, privacy: .public) started")
        let started = ContinuousClock.now
        do {
            let jsonString = try await raceAgainstTimeout(method: method) { [runtime] in
                let result = try await runtime.page.callJavaScript(
                    "return await window.cuePhotos.callJSON(method, argsJSON)",
                    arguments: ["method": method, "argsJSON": argsJSON],
                    contentWorld: runtime.bridgeWorld
                )
                guard let jsonString = result as? String else {
                    throw PhotosError.badBridgeResponse
                }
                return jsonString
            }
            let elapsed = started.duration(to: .now).components.seconds
            log.info("rpc \(method, privacy: .public) ok in \(elapsed) s")
            return Data(jsonString.utf8)
        } catch let error as NSError where error.domain == WKError.errorDomain {
            if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
                log.error("rpc \(method, privacy: .public) failed: \(message, privacy: .private)")
                throw PhotosError.bridge(message)
            }
            log.error("rpc \(method, privacy: .public) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static let rpcTimeout: Duration = .seconds(60)

    private func raceAgainstTimeout(
        method: String,
        _ operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox(continuation)
            let work = Task {
                do {
                    box.resume(.success(try await operation()))
                } catch {
                    box.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: Self.rpcTimeout)
                if box.resume(.failure(PhotosError.rpcTimeout(method))) {
                    // the JS promise may settle much later; nobody is listening
                    work.cancel()
                }
            }
        }
    }

    private func reportDrops(_ dropped: Int, in method: String) {
        if dropped > 0 {
            log.warning("\(method, privacy: .public): dropped \(dropped) undecodable items")
        }
    }

    private func json(_ value: (some Encodable)?) throws -> String {
        guard let value else { return "null" }
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class ResumeBox {
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<String, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

private nonisolated struct BridgeEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let value: T?
    let error: String?
    let stack: String?
    let diag: BridgeDiag?
}

private nonisolated struct BridgeNoValue: Decodable, Sendable {}

private nonisolated struct BridgeDiag: Decodable, Sendable, CustomStringConvertible {
    let href: String?
    let pathname: String?
    let hasWiz: Bool?
    let atLength: Int?
    let hasFsid: Bool?
    let hasBl: Bool?
    let path: String?

    var description: String {
        "href=\(href ?? "nil") path=\(path ?? "nil") hasWiz=\(hasWiz ?? false) "
            + "atLength=\(atLength.map(String.init) ?? "nil") hasFsid=\(hasFsid ?? false) hasBl=\(hasBl ?? false)"
    }
}

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
