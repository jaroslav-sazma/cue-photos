import Foundation
import WebKit
import os

// Media URLs (lh3.googleusercontent.com thumbnails and original downloads) need the
// signed-in session: a bare GET gets Google's "denied" placeholder. This session mirrors
// the webview's cookies into an in-memory store (never persisted) with header parity.
actor GoogleSession {
    private let runtime: WebRuntime
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage?
    private var userAgent: String?
    private var cookiesSynced = false
    private var syncTask: Task<Void, Error>?
    private let log = Logger(subsystem: "app.cue.photos", category: "googlesession")

    init(runtime: WebRuntime) {
        self.runtime = runtime
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        cookieStorage = configuration.httpCookieStorage
        session = URLSession(configuration: configuration)
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await syncCookiesIfNeeded()
        let (data, response) = try await perform(url)
        // Expired or stale-session URLs come back 400/403; one cookie resync + retry
        if response.statusCode == 400 || response.statusCode == 403 {
            log.debug("media GET \(response.statusCode), resyncing cookies and retrying once")
            try await syncCookies()
            return try await perform(url)
        }
        return (data, response)
    }

    // streams to a temp file; originals (especially =dv videos) must not live in RAM
    func download(from url: URL) async throws -> (URL, HTTPURLResponse) {
        try await syncCookiesIfNeeded()
        var request = URLRequest(url: url)
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("https://photos.google.com/", forHTTPHeaderField: "Referer")
        let (fileURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PhotosError.mediaFetch("not an HTTP response")
        }
        if http.statusCode == 400 || http.statusCode == 403 {
            try? FileManager.default.removeItem(at: fileURL)
            try await syncCookies()
            let (retryURL, retryResponse) = try await session.download(for: request)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw PhotosError.mediaFetch("not an HTTP response")
            }
            return (retryURL, retryHTTP)
        }
        return (fileURL, http)
    }

    private func perform(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("https://photos.google.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PhotosError.mediaFetch("not an HTTP response")
        }
        return (data, http)
    }

    // after an account switch the mirrored cookies belong to the old session
    func invalidate() {
        cookiesSynced = false
        userAgent = nil
        cookieStorage?.cookies?.forEach { cookieStorage?.deleteCookie($0) }
    }

    private nonisolated static func isGoogleDomain(_ domain: String) -> Bool {
        let trimmed = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return ["google.com", "googleusercontent.com", "youtube.com"].contains { suffix in
            trimmed == suffix || trimmed.hasSuffix("." + suffix)
        }
    }

    private func syncCookiesIfNeeded() async throws {
        guard !cookiesSynced else { return }
        try await syncCookies()
    }

    // single-flight: the first burst of thumbnails must not trigger parallel syncs
    private func syncCookies() async throws {
        if let syncTask {
            return try await syncTask.value
        }
        let task = Task { try await performSync() }
        syncTask = task
        defer { syncTask = nil }
        try await task.value
    }

    private func performSync() async throws {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        if userAgent == nil {
            userAgent = try await runtime.page.callJavaScript(
                "return navigator.userAgent",
                contentWorld: .page
            ) as? String
        }
        var copied = 0
        for cookie in cookies where Self.isGoogleDomain(cookie.domain) {
            cookieStorage?.setCookie(cookie)
            copied += 1
        }
        cookiesSynced = true
        log.debug("synced \(copied) cookies from the webview session")
    }
}
