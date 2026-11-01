import WebKit
import Observation
import os

@Observable
final class WebRuntime {
    enum State: Equatable {
        case starting
        case needsLogin
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var lastProgressLine: String?
    // oPEP7c is the signed-in account identity; the app model resets per-account
    // state when it changes between sessions
    private(set) var accountID: String?

    let page: WebPage
    // The bridge lives in a private content world: page scripts cannot see, replace
    // or detect window.cuePhotos, and the bridge gets untouched built-ins
    let bridgeWorld = WKContentWorld.world(name: "cuePhotos")

    private let log = Logger(subsystem: "app.cue.photos", category: "webruntime")
    private static let photosURL = URL(string: "https://photos.google.com/")!
    private static let loginURL =
        URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fphotos.google.com%2F")!

    // Stale async session checks must not overwrite the state of a newer navigation
    private var sessionGeneration = 0
    private var navigationMonitor: Task<Void, Never>?
    private var injectionTask: Task<Void, Error>?

    init() {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        let world = bridgeWorld
        let progress = ProgressMessageHandler()
        configuration.userContentController.add(progress, contentWorld: world, name: "cuePhotosLog")
        page = WebPage(configuration: configuration)
        progress.onLine = { [weak self] line in self?.lastProgressLine = line }
        #if DEBUG
        page.isInspectable = true
        #endif
    }

    func start() {
        guard navigationMonitor == nil else { return }
        navigationMonitor = Task { await monitorNavigations() }
        load()
    }

    func load() {
        sessionGeneration += 1
        injectionTask = nil
        state = .starting
        page.load(Self.photosURL)
    }

    private func monitorNavigations() async {
        while !Task.isCancelled {
            do {
                for try await event in page.navigations where event == .finished {
                    sessionGeneration += 1
                    await checkSession(generation: sessionGeneration)
                }
                return
            } catch let error as WebPage.NavigationError {
                switch error {
                case .webContentProcessTerminated:
                    log.warning("web content process terminated, reloading")
                    load()
                case .failedProvisionalNavigation(let underlying):
                    handleNavigationError(underlying)
                case .pageClosed:
                    return
                case .invalidURL:
                    state = .failed("Invalid URL.")
                @unknown default:
                    handleNavigationError(error)
                }
            } catch {
                handleNavigationError(error)
            }
        }
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        // NSURLErrorCancelled and WebKit 102 (frame load interrupted) are routine
        // during Google's login redirects, not failures
        if nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        state = .failed(error.localizedDescription)
    }

    private func checkSession(generation: Int) async {
        guard generation == sessionGeneration else { return }
        let host = page.url?.host() ?? ""
        guard host == "photos.google.com" else {
            state = .needsLogin
            routeToLoginIfNeeded(host: host)
            return
        }
        do {
            // SNlM0e is the "at" RPC token gptk signs requests with; a Wiz page
            // without it is a logged-out shell, not a session
            let hasSession = try await page.callJavaScript(
                """
                return typeof WIZ_global_data !== 'undefined'
                    && typeof WIZ_global_data.SNlM0e === 'string'
                    && WIZ_global_data.SNlM0e.length > 0
                """,
                contentWorld: .page
            ) as? Bool ?? false
            guard generation == sessionGeneration else { return }
            guard hasSession else {
                state = .needsLogin
                routeToLoginIfNeeded(host: host)
                return
            }
            let account = try await page.callJavaScript(
                "return typeof WIZ_global_data.oPEP7c === 'string' ? WIZ_global_data.oPEP7c : ''",
                contentWorld: .page
            ) as? String
            guard generation == sessionGeneration else { return }
            accountID = (account?.isEmpty == false) ? account : nil
            try await injectBridgeIfNeeded()
            guard generation == sessionGeneration else { return }
            state = .ready
        } catch {
            guard generation == sessionGeneration else { return }
            log.error("session check failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // Logged out, photos.google.com bounces to its marketing page; route straight to the
    // sign-in form instead. Only these two known logged-out hosts are rerouted, so the
    // user can still follow help links inside the login flow.
    private func routeToLoginIfNeeded(host: String) {
        guard host == "photos.google.com" || host == "www.google.com" else { return }
        page.load(Self.loginURL)
    }

    private func injectBridgeIfNeeded() async throws {
        if let injectionTask {
            return try await injectionTask.value
        }
        let task = Task {
            let present = try await page.callJavaScript(
                "return typeof window.cuePhotos !== 'undefined'",
                contentWorld: bridgeWorld
            ) as? Bool ?? false
            guard !present else { return }
            guard let url = Bundle.main.url(forResource: "WebBridge", withExtension: "js") else {
                throw PhotosError.bridgeMissing
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            // The isolated world shares the DOM, origin and cookies but not page JS
            // globals, so WIZ_global_data (read by gptk at module evaluation) is
            // seeded across before the bundle runs
            let wizJSON = try await page.callJavaScript(
                "return JSON.stringify(WIZ_global_data)",
                contentWorld: .page
            ) as? String ?? "{}"
            _ = try await page.callJavaScript(
                "window.WIZ_global_data = JSON.parse(wiz); return true",
                arguments: ["wiz": wizJSON],
                contentWorld: bridgeWorld
            )
            _ = try await page.callJavaScript(script, contentWorld: bridgeWorld)
            log.info("bridge injected")
        }
        injectionTask = task
        defer { injectionTask = nil }
        try await task.value
    }
}

enum PhotosError: LocalizedError {
    case bridgeMissing
    case notReady
    case badBridgeResponse
    case bridge(String)
    case mediaFetch(String)
    case rpcTimeout(String)

    var errorDescription: String? {
        switch self {
        case .bridgeMissing: "WebBridge.js is missing from the app bundle."
        case .notReady: "Not connected to Google Photos yet."
        case .badBridgeResponse: "Unexpected response from the Google Photos bridge."
        case .bridge(let message): "Google Photos bridge error: \(message)"
        case .mediaFetch(let message): "Media fetch failed: \(message)"
        case .rpcTimeout(let method): "Google Photos did not answer the \(method) request within 60 seconds."
        }
    }
}

private final class ProgressMessageHandler: NSObject, WKScriptMessageHandler {
    var onLine: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let line = body["message"] as? String else { return }
        onLine?(line)
    }
}
