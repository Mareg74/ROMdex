import Foundation

struct MondemulAdapter: SiteAdapter {
    let id = "mondemul"
    let displayName = "Mondemul"
    private let baseURL = URL(string: "https://www.mondemul.me")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            return try await searchOnPlatform(trimmed, platform: platform)
        }

        let supported = Platform.allCases.filter { $0.mondemulID != nil }
        return await ParallelFetch.map(supported) { platform in
            (try? await self.searchOnPlatform(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
    }

    private func searchOnPlatform(_ query: String, platform: Platform) async throws -> [GameResult] {
        guard let systemID = platform.mondemulID else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://www.mondemul.me/recherche.php")!
        components.queryItems = [
            URLQueryItem(name: "recherche", value: query),
            URLQueryItem(name: "plateforme", value: systemID)
        ]

        guard let url = components.url else { return [] }
        let html = try await HTTPClient.fetchString(from: url)
        return parse(html: html, platform: platform)
    }

    private func parse(html: String, platform: Platform) -> [GameResult] {
        let patterns = [
            #"<a href="(fiche\.php\?[^"]+)"[^>]*>([^<]+)</a>"#,
            #"<a href="(/fiche[^"]+)"[^>]*>([^<]+)</a>"#,
            #"<a href="(https://www\.mondemul\.me/[^"]+)"[^>]*>([^<]+)</a>"#
        ]

        var seen = Set<String>()
        var results: [GameResult] = []

        for pattern in patterns {
            for match in HTMLParser.matches(in: html, pattern: pattern) {
                let path = match.groups[0]
                let title = HTMLParser.decodeEntities(match.groups[1]).trimmingCharacters(in: .whitespacesAndNewlines)

                guard !title.isEmpty else { continue }
                guard title.count > 2 else { continue }
                guard !title.localizedCaseInsensitiveContains("mondemul") else { continue }
                guard let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
                guard url.absoluteString.contains("fiche") || url.absoluteString.contains("jeu") else { continue }

                guard seen.insert(url.absoluteString).inserted else { continue }

                results.append(
                    GameResult(
                        title: title,
                        platform: platform,
                        sourceSite: displayName,
                        pageURL: url,
                        regionHint: path
                    )
                )
            }
        }

        return results
    }
}
