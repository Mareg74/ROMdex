import AppKit
import Foundation
import WebKit

/// Cache LRU des aperçus de pages (max 10 `WKWebView` préchargés), verrouillés au domaine d’origine.
@MainActor
final class PagePreviewCache {
    static let shared = PagePreviewCache()

    private let maxEntries = 10
    private var order: [URL] = []
    private var webViews: [URL: WKWebView] = [:]
    /// Les delegates WK sont weak : on garde une référence forte ici.
    private var coordinators: [URL: DomainLockedWebCoordinator] = [:]

    private init() {}

    /// Retourne une webview déjà chargée (ou la crée et la précharge).
    func webView(for url: URL) -> WKWebView {
        if let existing = webViews[url] {
            touch(url)
            return existing
        }

        evictIfNeeded()

        let host = DomainLockedWebCoordinator.baseHost(from: url)
        let coordinator = DomainLockedWebCoordinator(allowedHost: host)
        let config = DomainLockedWebCoordinator.makeConfiguration()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.load(URLRequest(url: url))

        webViews[url] = webView
        coordinators[url] = coordinator
        order.append(url)
        return webView
    }

    func preload(_ url: URL) {
        _ = webView(for: url)
    }

    /// Recharge l’URL d’origine dans la webview existante (second clic sur la source).
    func reload(_ url: URL) {
        if let existing = webViews[url] {
            touch(url)
            existing.stopLoading()
            existing.load(URLRequest(url: url))
            return
        }
        preload(url)
    }

    func preload(urls: [URL]) {
        for url in urls.prefix(maxEntries) {
            preload(url)
        }
    }

    func contains(_ url: URL) -> Bool {
        webViews[url] != nil
    }

    /// Extrait la jaquette RomsFun depuis l’aperçu déjà chargé (évite un 2ᵉ fetch).
    func romsFunCoverURL(for pageURL: URL, timeout: TimeInterval = 10) async -> URL? {
        let host = pageURL.host?.lowercased() ?? ""
        guard host.contains("romsfun.com") else { return nil }

        let wv = webView(for: pageURL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cover = await evaluateRomsFunCover(in: wv) {
                return cover
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return await evaluateRomsFunCover(in: wv)
    }

    private func evaluateRomsFunCover(in webView: WKWebView) async -> URL? {
        guard let raw = try? await webView.evaluateJavaScript(CoverArtParser.romsFunCoverJavaScript),
              let s = raw as? String,
              let url = URL(string: s) else {
            return nil
        }
        return CoverArtParser.preferOriginalURL(url)
    }

    func clear() {
        for webView in webViews.values {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        webViews.removeAll()
        coordinators.removeAll()
        order.removeAll()
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    private func evictIfNeeded() {
        while order.count >= maxEntries, let oldest = order.first {
            order.removeFirst()
            if let webView = webViews.removeValue(forKey: oldest) {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.removeFromSuperview()
            }
            coordinators.removeValue(forKey: oldest)
        }
    }
}
