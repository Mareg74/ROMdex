import Foundation

/// DownloadGamePSP — catalogue PSP / PPSSPP. PS Vita hors catalogue ROMdex.
struct DownloadGamePSPAdapter: SiteAdapter {
    let id = "downloadgamepsp"
    let displayName = "DownloadGamePSP"

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform, platform != .psp {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://downloadgamepsp.org/")!
        components.queryItems = [URLQueryItem(name: "s", value: trimmed)]
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        return parseSearchResults(html: html).filter { $0.platform == .psp }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard platform == .psp else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        guard let url = URL(string: "https://downloadgamepsp.org/list-all-game-psp-ppsspp/") else {
            return []
        }

        let html = try await HTTPClient.fetchString(from: url, timeout: 45)
        let games = parseListAll(html: html, platform: .psp)
        CatalogBrowseProgress.reportGames(site: displayName, games)
        return games
    }

    private func parseListAll(html: String, platform: Platform) -> [GameResult] {
        let pattern = #"<a class="title" href="(https?://[^"]+)"[^>]*>\s*([^<]+?)\s*</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let link = match.groups[0]
            let title = cleanTitle(HTMLParser.decodeEntities(match.groups[1]))
            guard title.count > 1, let pageURL = URL(string: link) else { continue }
            guard isGamePostURL(pageURL) else { continue }
            // Exclure les fiches purement Vita si le slug le dit clairement.
            let path = pageURL.path.lowercased()
            if path.contains("psvita") && !path.contains("psp") { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: pageURL.lastPathComponent
                )
            )
        }
        return results
    }

    private func parseSearchResults(html: String) -> [GameResult] {
        let pattern = #"<h[123][^>]*>\s*<a[^>]+href="(https?://[^"]+)"[^>]*>\s*([^<]+?)\s*</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let link = match.groups[0]
            let title = cleanTitle(HTMLParser.decodeEntities(match.groups[1]))
            guard title.count > 1, let pageURL = URL(string: link) else { continue }
            guard isGamePostURL(pageURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            let path = pageURL.path.lowercased()
            let platform: Platform
            if path.contains("psvita") && !path.contains("psp") {
                continue // Vita hors ROMdex
            } else if path.contains("psp") || path.contains("ppsspp") {
                platform = .psp
            } else {
                platform = .psp
            }

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: pageURL.lastPathComponent
                )
            )
        }
        return results
    }

    private func isGamePostURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host.contains("downloadgamepsp") else { return false }
        let path = url.path.lowercased()
        let blocked = ["/category/", "/tag/", "/page/", "/wp-", "/list-", "/dmca", "/guide", "/feed"]
        if blocked.contains(where: { path.contains($0) }) { return false }
        return url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count > 2
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = raw
        for pattern in [#"\s*[-–|].*$"#, #"™|®"#] {
            title = title.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return title
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
