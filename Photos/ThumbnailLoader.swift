import CoreGraphics
import Foundation
import ImageIO
import os

// Authenticated fetch, ImageIO downsampled decode off the main thread, cost-limited
// in-memory cache (never disk — see PRIVACY.md), in-flight de-duplication.
actor ThumbnailLoader {
    private let googleSession: GoogleSession
    private let cache = NSCache<NSString, CachedThumbnail>()
    // decoded images are ~1 MB each and evict fast; the encoded originals are
    // ~30 kB, so this tier keeps whole albums re-decodable without the network
    private let dataCache = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<(CGImage, Data?), Error>] = [:]
    // scale-design bound on concurrent network fetches; fast scrolling must not
    // queue thousands of requests ahead of the visible items
    private let gate = RPCLimiter(limit: 24)
    private let log = Logger(subsystem: "app.cue.photos", category: "thumbnails")

    init(session: GoogleSession) {
        googleSession = session
        // small on purpose: a miss re-decodes from the bytes tier in milliseconds,
        // and NSCache treats the limit loosely enough without a large ceiling
        cache.totalCostLimit = 128 * 1024 * 1024
        dataCache.totalCostLimit = 128 * 1024 * 1024
    }

    func clearCache() {
        cache.removeAllObjects()
        dataCache.removeAllObjects()
    }

    // cacheKey outlives the URL on purpose: thumbnail base URLs rotate and expire
    func thumbnail(base: String, pixelSize: Int, cacheKey: String, crop: Bool = true) async throws -> CGImage {
        let key = "\(cacheKey)#\(pixelSize)\(crop ? "" : "f")" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.image
        }
        if let running = inFlight[key as String] {
            return try await running.value.0
        }
        let session = googleSession
        let gate = gate
        let encoded = dataCache.object(forKey: key) as Data?
        let task = Task.detached(priority: .utility) { () -> (CGImage, Data?) in
            if let encoded {
                return (try Self.decode(encoded, maxPixelSize: pixelSize), nil)
            }
            // -c crops square, -k-no drops the video watermark and the auth requirement
            // per gptk's parser notes; cookies cover what the flags don't
            let flags = crop ? "-c-k-no" : "-k-no"
            guard let url = URL(string: "\(base)=w\(pixelSize)-h\(pixelSize)\(flags)") else {
                throw PhotosError.mediaFetch("invalid thumbnail URL")
            }
            try await gate.acquire()
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await session.data(from: url)
                await gate.release()
            } catch {
                await gate.release()
                throw error
            }
            guard response.statusCode == 200 else {
                throw PhotosError.mediaFetch("thumbnail HTTP \(response.statusCode)")
            }
            return (try Self.decode(data, maxPixelSize: pixelSize), data)
        }
        inFlight[key as String] = task
        defer { inFlight[key as String] = nil }
        do {
            let (image, fetched) = try await task.value
            cache.setObject(CachedThumbnail(image), forKey: key, cost: image.bytesPerRow * image.height)
            if let fetched {
                dataCache.setObject(fetched as NSData, forKey: key, cost: fetched.count)
            }
            return image
        } catch {
            log.debug("thumbnail load failed: \(error.localizedDescription)")
            throw error
        }
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: Int) throws -> CGImage {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            throw PhotosError.mediaFetch("undecodable thumbnail data")
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // forces the decode here, off the main thread, not during the CA commit
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PhotosError.mediaFetch("thumbnail decode failed")
        }
        return image
    }
}

private nonisolated final class CachedThumbnail {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
