import AppKit
import Foundation
import WebKit

/// Récupère le HTML via `WKWebView` (cookies + JS) pour passer les challenges Cloudflare.
/// File d’attente sérialisée — une navigation à la fois. Les requêtes « haute priorité »
/// (fiche jeu ouverte) passent devant l’enrichissement catalogue.
@MainActor
final class BrowserHTMLClient: NSObject, WKNavigationDelegate {
    static let shared = BrowserHTMLClient()

    enum FetchPriority {
        case normal
        case high
    }

    private let webView: WKWebView
    private var busy = false
    private var highPriorityWaiters: [CheckedContinuation<Void, Never>] = []
    private var normalWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var loadGeneration = 0
    private var navigationTimeoutTask: Task<Void, Never>?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.customUserAgent = HTTPClient.userAgent
        self.webView = view
        super.init()
        view.navigationDelegate = self
    }

    /// Charge `url`, attend la fin du challenge Cloudflare si besoin, renvoie `outerHTML`.
    func fetchHTML(from url: URL, timeout: TimeInterval = 55, priority: FetchPriority = .normal) async throws -> String {
        await acquire(priority: priority)
        defer { release() }
        return try await loadSettledHTML(from: url, timeout: timeout)
    }

    /// Charge une fiche RomsFun et extrait l’URL de jaquette (HTML + JS DOM).
    func fetchRomsFunCover(from url: URL, timeout: TimeInterval = 45, priority: FetchPriority = .normal) async throws -> URL? {
        await acquire(priority: priority)
        defer { release() }

        let html = try await loadSettledHTML(from: url, timeout: timeout)
        if let fromHTML = CoverArtParser.romsFunCover(fromHTML: html) {
            return fromHTML
        }

        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, Math.min(800, document.body.scrollHeight));")
        try await Task.sleep(nanoseconds: 400_000_000)
        let raw = try await webView.evaluateJavaScript(CoverArtParser.romsFunCoverJavaScript)
        if let s = raw as? String, let cover = URL(string: s) {
            return CoverArtParser.preferOriginalURL(cover)
        }
        let html2 = try await documentHTML()
        return CoverArtParser.romsFunCover(fromHTML: html2)
    }

    /// Page listing RomsFun : HTML + jaquettes extraites du DOM (lazy-load).
    func fetchRomsFunListing(from url: URL, timeout: TimeInterval = 55) async throws -> (html: String, thumbs: [String: URL]) {
        await acquire(priority: .normal)
        defer { release() }

        let settled = try await loadSettledHTML(from: url, timeout: timeout)

        // Déclenche le lazy-load des vignettes.
        _ = try? await webView.evaluateJavaScript(
            "window.scrollTo(0, Math.min(document.body.scrollHeight, 2400));"
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0);")
        try await Task.sleep(nanoseconds: 200_000_000)

        let thumbs = await evaluateRomsFunListingThumbs()
        let htmlAfter = (try? await documentHTML()) ?? settled
        return (htmlAfter, thumbs)
    }

    /// Navigation + attente CF — appelant doit déjà tenir `acquire()`.
    private func loadSettledHTML(from url: URL, timeout: TimeInterval) async throws -> String {
        CatalogBrowseProgress.reportFetching(url)

        loadGeneration += 1
        let generation = loadGeneration
        webView.stopLoading()
        navigationTimeoutTask?.cancel()

        let navTimeout = min(timeout, 40)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadWaiters.append(continuation)
            webView.load(URLRequest(url: url, timeoutInterval: navTimeout))
            navigationTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(navTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard !self.loadWaiters.isEmpty else { return }
                self.webView.stopLoading()
                self.finishLoad(error: SiteAdapterError.blocked(url.host ?? "Site"))
            }
        }

        guard generation == loadGeneration else {
            throw SiteAdapterError.invalidResponse
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let title = webView.title ?? ""
            let html = try await documentHTML()
            if !Self.isCloudflareChallenge(title: title, html: html) {
                try await Task.sleep(nanoseconds: 350_000_000)
                let settled = try await documentHTML()
                let settledTitle = webView.title ?? ""
                if !Self.isCloudflareChallenge(title: settledTitle, html: settled) {
                    if settled.count < 800 {
                        throw SiteAdapterError.invalidResponse
                    }
                    return settled
                }
            }
            try await Task.sleep(nanoseconds: 450_000_000)
        }

        throw SiteAdapterError.blocked(url.host ?? "Site")
    }

    private func evaluateRomsFunListingThumbs() async -> [String: URL] {
        guard let raw = try? await webView.evaluateJavaScript(CoverArtParser.romsFunListingThumbsJavaScript),
              let json = raw as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        var map: [String: URL] = [:]
        for (path, urlString) in dict {
            guard let url = URL(string: urlString), !urlString.isEmpty else { continue }
            map[path] = CoverArtParser.preferOriginalURL(url)
        }
        return map
    }

    // MARK: - Queue

    private func acquire(priority: FetchPriority) async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            switch priority {
            case .high:
                highPriorityWaiters.append(continuation)
            case .normal:
                normalWaiters.append(continuation)
            }
        }
    }

    private func release() {
        if let next = highPriorityWaiters.first {
            highPriorityWaiters.removeFirst()
            next.resume()
        } else if let next = normalWaiters.first {
            normalWaiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }

    // MARK: - HTML

    private func documentHTML() async throws -> String {
        let raw = try await webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
        guard let html = raw as? String, !html.isEmpty else {
            throw SiteAdapterError.invalidResponse
        }
        return html
    }

    static func isCloudflareChallenge(title: String, html: String) -> Bool {
        if looksLikeSiteContent(title: title, html: html) {
            return false
        }

        let t = title.lowercased()
        if t.contains("just a moment")
            || t.contains("attention required")
            || t.contains("security verification")
            || t.contains("performing security") {
            return true
        }

        let h = html.lowercased()
        if h.contains("cf-browser-verification")
            || h.contains("cdn-cgi/challenge-platform") {
            return true
        }
        if h.contains("just a moment") && h.contains("cloudflare") {
            return true
        }
        if h.contains("enable javascript and cookies to continue") {
            return true
        }
        return false
    }

    /// Contenu catalogue / page réelle (pas l’interstitiel CF).
    static func looksLikeSiteContent(title: String, html: String) -> Bool {
        let t = title.lowercased()
        if t.contains("just a moment")
            || t.contains("attention required")
            || t.isEmpty && html.count < 1500 {
            return false
        }
        if html.localizedCaseInsensitiveContains("Popular ROMs")
            || html.localizedCaseInsensitiveContains("Latest ROMs")
            || html.localizedCaseInsensitiveContains("List of available consoles")
            || html.localizedCaseInsensitiveContains("Download ROM")
            || html.localizedCaseInsensitiveContains("Related ROMs") {
            return true
        }
        // Liens fiches jeux RomsFun.
        if html.range(of: #"/roms/[a-z0-9-]+/[a-z0-9-]+\.html"#, options: .regularExpression) != nil {
            return true
        }
        // Titres fiches : « Animorphs ROM - Nintendo GBC »
        if t.contains(" rom") && (t.contains("nintendo") || t.contains("playstation") || t.contains("xbox") || t.contains("sega") || t.contains("gbc") || t.contains("gba") || t.contains("nes") || t.contains("snes")) {
            return true
        }
        return false
    }

    private func finishLoad(error: Error?) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(error: SiteAdapterError.network(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(error: SiteAdapterError.network(error))
    }
}
