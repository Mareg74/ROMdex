import Foundation

struct CDRomanceAdapter: SiteAdapter {
    let id = "cdromance"
    let displayName = "CDRomance"
    private let baseURL = URL(string: "https://cdromance.org")!
    private let maxBrowsePages = 80

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            return try await searchOnPlatform(trimmed, platform: platform)
        }

        let supported = Platform.allCases.filter { $0.cdRomanceCategory != nil }
        return await ParallelFetch.map(supported) { platform in
            (try? await self.searchOnPlatform(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let postType = platform.cdRomancePostType else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        return try await PaginatedBrowse.collect(through: maxBrowsePages, siteName: displayName) { page in
            var components = URLComponents(string: "https://cdromance.org/wp-json/wp/v2/\(postType)")!
            components.queryItems = [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components.url else { return [] }

            let json = try await HTTPClient.fetchJSON(from: url, timeout: 30)
            guard let posts = json as? [[String: Any]] else { return [] }
            return posts.compactMap { parseRESTPost($0, platform: platform) }
        }
    }

    private func parseRESTPost(_ post: [String: Any], platform: Platform) -> GameResult? {
        guard let link = post["link"] as? String,
              let pageURL = URL(string: link) else { return nil }

        let titleRendered: String
        if let titleObj = post["title"] as? [String: Any],
           let rendered = titleObj["rendered"] as? String {
            titleRendered = rendered
        } else if let t = post["title"] as? String {
            titleRendered = t
        } else {
            return nil
        }

        let title = HTMLParser.decodeEntities(titleRendered)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count > 1 else { return nil }

        return GameResult(
            title: title,
            platform: platform,
            sourceSite: displayName,
            pageURL: pageURL,
            regionHint: pageURL.lastPathComponent
        )
    }

    private func searchOnPlatform(_ query: String, platform: Platform) async throws -> [GameResult] {
        guard platform.cdRomanceCategory != nil else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://cdromance.org/")!
        components.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "post_type", value: "post")
        ]

        guard let url = components.url else { return [] }

        do {
            let html = try await HTTPClient.fetchString(from: url)
            return parse(html: html, platform: platform)
        } catch SiteAdapterError.blocked {
            throw SiteAdapterError.blocked(displayName)
        }
    }

    private func parse(html: String, platform: Platform) -> [GameResult] {
        let titlePattern = #"<h2 class="entry-title"><a href="([^"]+)"[^>]*>([^<]+)</a></h2>"#
        let genericPattern = #"<a href="(https://cdromance\.org/[^"]+)"[^>]*rel="bookmark"[^>]*>([^<]+)</a>"#

        let matches = HTMLParser.matches(in: html, pattern: titlePattern)
            + HTMLParser.matches(in: html, pattern: genericPattern)

        var seen = Set<String>()
        var results: [GameResult] = []

        for match in matches {
            let link = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = URL(string: link) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: url,
                    regionHint: link
                )
            )
        }

        return results
    }
}
