import Foundation

enum HTTPClient {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func fetchString(from url: URL, timeout: TimeInterval = 20) async throws -> String {
        let data = try await fetchData(from: url, timeout: timeout)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SiteAdapterError.invalidResponse
        }

        if html.localizedCaseInsensitiveContains("403 Access Forbidden")
            || html.localizedCaseInsensitiveContains("n'est pas autorisé à poursuivre") {
            throw SiteAdapterError.blocked(url.host ?? "Site")
        }

        return html
    }

    static func fetchData(from url: URL, timeout: TimeInterval = 20, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await HostFetchLimiter.shared.withPermit(for: url) {
            try await performFetchData(from: url, timeout: timeout, method: method, body: body)
        }
    }

    private static func performFetchData(from url: URL, timeout: TimeInterval, method: String, body: Data?) async throws -> Data {
        CatalogBrowseProgress.reportFetching(url)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json", forHTTPHeaderField: "Accept")
        request.setValue("fr-FR,fr;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SiteAdapterError.invalidResponse
        }

        guard (200 ... 399).contains(http.statusCode) else {
            if http.statusCode == 403 {
                throw SiteAdapterError.blocked(url.host ?? "Site")
            }
            if http.statusCode == 404 {
                throw SiteAdapterError.notFound(url.host ?? "Site")
            }
            if (520 ... 530).contains(http.statusCode) {
                throw SiteAdapterError.blocked(url.host ?? "Site")
            }
            throw SiteAdapterError.invalidResponse
        }

        guard !data.isEmpty else {
            throw SiteAdapterError.invalidResponse
        }

        return data
    }

    static func fetchJSON(from url: URL, timeout: TimeInterval = 20) async throws -> Any {
        let data = try await fetchData(from: url, timeout: timeout)
        return try JSONSerialization.jsonObject(with: data)
    }

    static func postForm(url: URL, fields: [String: String], timeout: TimeInterval = 25) async throws -> Data {
        try await HostFetchLimiter.shared.withPermit(for: url) {
            try await performPostForm(url: url, fields: fields, timeout: timeout)
        }
    }

    private static func performPostForm(url: URL, fields: [String: String], timeout: TimeInterval) async throws -> Data {
        CatalogBrowseProgress.reportFetching(url)

        let body = fields
            .map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://xbox360iso.net/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 399).contains(http.statusCode) else {
            throw SiteAdapterError.invalidResponse
        }
        guard !data.isEmpty else { throw SiteAdapterError.invalidResponse }
        return data
    }

    static func absoluteURL(_ path: String, base: URL) -> URL? {
        if path.hasPrefix("http") {
            return URL(string: path)
        }
        if path.hasPrefix("//") {
            return URL(string: "https:" + path)
        }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }
}

enum HTMLParser {
    static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func matches(in html: String, pattern: String) -> [(full: String, groups: [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard let fullRange = Range(match.range, in: html) else { return nil }
            let groups = (1 ..< match.numberOfRanges).compactMap { index -> String? in
                guard let groupRange = Range(match.range(at: index), in: html) else { return nil }
                return String(html[groupRange])
            }
            return (String(html[fullRange]), groups)
        }
    }
}
