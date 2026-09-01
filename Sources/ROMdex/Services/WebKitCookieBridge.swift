import Foundation
import WebKit

/// Pont cookies `WKWebsiteDataStore` → `URLSession` (CF / RomsFun).
enum WebKitCookieBridge {
    /// Cookies du store WebKit partagé (aperçus + BrowserHTMLClient + déblocage).
    @MainActor
    static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// Télécharge une ressource avec cookies WebKit + UA navigateur (+ Referer optionnel).
    @MainActor
    static func fetchData(from url: URL, referer: URL? = nil, timeout: TimeInterval = 20) async throws -> Data {
        let cookies = await allCookies()
        let storage = HTTPCookieStorage()
        for cookie in cookies where cookieApplies(cookie, to: url) {
            storage.setCookie(cookie)
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = storage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("fr-FR,fr;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        } else if let host = url.host {
            request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }

        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw SiteAdapterError.invalidResponse
        }
        guard !data.isEmpty else { throw SiteAdapterError.invalidResponse }
        return data
    }

    /// Sites dont les assets passent souvent derrière Cloudflare.
    static func needsWebKitCookies(for url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("romsfun.com")
    }

    private static func cookieApplies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
    }
}
