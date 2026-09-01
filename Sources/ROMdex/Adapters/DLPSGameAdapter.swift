import Foundation

/// DLPSGame — catalogues PS2 / PS3 (WordPress). Browse via pages « list all » (~1 requête),
/// recherche via `?s=` + filtre plateforme. PS4/PS5 présents sur le site mais hors catalogue ROMdex.
struct DLPSGameAdapter: SiteAdapter {
    let id = "dlpsgame"
    let displayName = "DLPSGame"
    private let baseURL = URL(string: "https://dlpsgame.com")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            guard platform.dlpsGameListPath != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            return try await searchHTML(trimmed, platform: platform)
        }

        let merged = await ParallelFetch.map([Platform.ps2, .ps3]) { platform in
            (try? await self.searchHTML(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
        return dedupe(merged)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let listPath = platform.dlpsGameListPath else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        guard let url = URL(string: "https://dlpsgame.com/\(listPath)") else {
            return []
        }

        let html = try await HTTPClient.fetchString(from: url, timeout: 45)
        let games = parseListAll(html: html, platform: platform)
        CatalogBrowseProgress.reportGames(site: displayName, games)
        return games
    }

    // MARK: - Search

    private func searchHTML(_ query: String, platform: Platform) async throws -> [GameResult] {
        var components = URLComponents(string: "https://dlpsgame.com/")!
        components.queryItems = [URLQueryItem(name: "s", value: query)]
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        let all = parseSearchResults(html: html)
        return all.filter { matchesPlatform($0, platform: platform) }
    }

    // MARK: - Parse

    /// Pages « List All Game PS2/PS3 » : `<a class="title" href="...">Title</a>`.
    private func parseListAll(html: String, platform: Platform) -> [GameResult] {
        let pattern = #"<a class="title" href="(https://dlpsgame\.com/[^"]+)"[^>]*>\s*([^<]+?)\s*</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let link = match.groups[0]
            let title = cleanTitle(HTMLParser.decodeEntities(match.groups[1]))
            guard title.count > 1, let pageURL = URL(string: link) else { continue }
            guard isGamePostURL(pageURL) else { continue }
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
        let pattern = #"<h[123][^>]*>\s*<a[^>]+href="(https://dlpsgame\.com/[^"]+)"[^>]*>\s*([^<]+?)\s*</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let link = match.groups[0]
            let title = cleanTitle(HTMLParser.decodeEntities(match.groups[1]))
            guard title.count > 1, let pageURL = URL(string: link) else { continue }
            guard isGamePostURL(pageURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            let platform = detectPlatform(from: pageURL) ?? .ps3
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

    private func matchesPlatform(_ result: GameResult, platform: Platform) -> Bool {
        if result.platform == platform { return true }
        return detectPlatform(from: result.pageURL) == platform
    }

    private func detectPlatform(from url: URL) -> Platform? {
        let path = url.path.lowercased()
        if path.contains("-ps2") || path.contains("/ps2") { return .ps2 }
        if path.contains("-ps5") || path.contains("/ps5") { return nil } // hors catalogue
        if path.contains("-ps4") || path.contains("/ps4") { return nil }
        if path.contains("-ps3") || path.contains("-psn") { return .ps3 }
        return nil
    }

    private func isGamePostURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let blocked = [
            "/category/", "/tag/", "/page/", "/wp-", "/list-", "/dmca",
            "/guide", "/daily-update", "/all-guide", "/contact", "/feed"
        ]
        if blocked.contains(where: { path.contains($0) }) { return false }
        let slug = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return slug.count > 2
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = raw
        for pattern in [
            #"\s*[-–|].*$"#,
            #"\s*\+\s*DLC.*$"#,
            #"™|®"#
        ] {
            title = title.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return title
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dedupe(_ results: [GameResult]) -> [GameResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.pageURL.absoluteString).inserted }
    }
}

extension Platform {
    /// Chemin page « list all » DLPSGame. `nil` = non supporté (PS4/PS5 hors enum, etc.).
    var dlpsGameListPath: String? {
        switch self {
        case .ps2: return "list-all-game-ps2/"
        case .ps3: return "list-all-game-ps3"
        default: return nil
        }
    }

    /// ID catégorie WordPress (recherche REST optionnelle).
    var dlpsGameCategoryID: Int? {
        switch self {
        case .ps2: return 5917
        case .ps3: return 64
        default: return nil
        }
    }
}
