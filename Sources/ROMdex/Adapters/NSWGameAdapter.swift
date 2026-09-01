import Foundation

/// NSWGame / NSWGF — catalogues Nintendo (Switch, Wii, Wii U, 3DS, DS).
/// Les pages « list all » sont sur nswgame.com ; les fiches pointent vers nswgf.com.
struct NSWGameAdapter: SiteAdapter {
    let id = "nswgame"
    let displayName = "NSWGame"
    private let listHost = "https://nswgame.com"
    private let searchHost = "https://nswgame.com"

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            guard platform.nswGameListPath != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            return try await searchHTML(trimmed, platform: platform)
        }

        let platforms = Platform.allCases.filter { $0.nswGameListPath != nil }
        let merged = await ParallelFetch.map(platforms) { platform in
            (try? await self.searchHTML(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
        return dedupe(merged)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let listPath = platform.nswGameListPath else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }
        guard let url = URL(string: "\(listHost)/\(listPath)") else { return [] }

        let html = try await HTTPClient.fetchString(from: url, timeout: 60)
        let games = parseListAll(html: html, platform: platform)
        CatalogBrowseProgress.reportGames(site: displayName, games)
        return games
    }

    private func searchHTML(_ query: String, platform: Platform) async throws -> [GameResult] {
        var components = URLComponents(string: "\(searchHost)/")!
        components.queryItems = [URLQueryItem(name: "s", value: query)]
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        return parseSearchResults(html: html).filter { matchesPlatform($0, platform: platform) }
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

            let platform = detectPlatform(from: pageURL) ?? .switchPlatform
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
        result.platform == platform || detectPlatform(from: result.pageURL) == platform
    }

    private func detectPlatform(from url: URL) -> Platform? {
        let path = url.path.lowercased()
        if path.contains("wii-u") || path.contains("wiiu") { return .wiiU }
        if path.contains("-wii-") || path.contains("-wii/") || path.hasSuffix("-wii") { return .wii }
        if path.contains("-3ds-") || path.contains("-3ds/") || path.contains("nintendo-3ds") { return .n3ds }
        if path.contains("-nds-") || path.contains("-ds-download") || path.contains("/ds-") { return .nds }
        if path.contains("nintendo-switch") || path.contains("-switch-") { return .switchPlatform }
        return nil
    }

    private func isGamePostURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host.contains("nswgame") || host.contains("nswgf") else { return false }
        let path = url.path.lowercased()
        let blocked = ["/category/", "/tag/", "/page/", "/wp-", "/list-", "/dmca", "/guide", "/feed"]
        if blocked.contains(where: { path.contains($0) }) { return false }
        return url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count > 2
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = raw
        for pattern in [#"\s*[-–|].*$"#, #"\s*\+\s*DLC.*$"#, #"™|®"#] {
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
    /// Page « list all » sur nswgame.com.
    var nswGameListPath: String? {
        switch self {
        case .switchPlatform: return "list-all-game-switch/"
        case .wii: return "list-all-game-wii/"
        case .wiiU: return "list-all-game-wii-u/"
        case .n3ds: return "list-all-game-3ds/"
        case .nds: return "list-all-game-ds/"
        default: return nil
        }
    }
}
