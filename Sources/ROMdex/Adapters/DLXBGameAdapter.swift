import Foundation

/// DownloadGameXbox / DLXBGame — Xbox classique + Xbox 360 (ISO / JTAG / XBLA).
/// Listes sur downloadgamexbox.com ; fiches sur dlxbgame.com.
struct DLXBGameAdapter: SiteAdapter {
    let id = "dlxbgame"
    let displayName = "DLXBGame"
    private let listHost = "https://downloadgamexbox.com"
    private let maxJTAGPages = 60

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            guard platform == .xbox || platform == .x360 else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            return try await searchHTML(trimmed, platform: platform)
        }

        let merged = await ParallelFetch.map([Platform.xbox, .x360]) { platform in
            (try? await self.searchHTML(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
        return dedupe(merged)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        switch platform {
        case .xbox:
            return try await browseListPaths([
                "list-all-game-xbox-classic/",
                "list-all-game-xbox/"
            ], platform: .xbox)

        case .x360:
            // ISO + XBLA (list all) + catalogue JTAG/RGH complet via REST (~5481).
            var all = try await browseListPaths([
                "list-all-game-xbox-iso/",
                "list-all-game-xbox-xbla-arcade/"
            ], platform: .x360)
            let jtag = try await browseJTAGREST()
            all = dedupe(all + jtag)
            return all

        default:
            throw SiteAdapterError.unsupportedPlatform(platform)
        }
    }

    // MARK: - List all

    private func browseListPaths(_ paths: [String], platform: Platform) async throws -> [GameResult] {
        let batches = await ParallelFetch.mapOptional(paths) { path -> [GameResult]? in
            guard let url = URL(string: "\(listHost)/\(path)") else { return nil }
            guard let html = try? await HTTPClient.fetchString(from: url, timeout: 60) else { return nil }
            return parseListAll(html: html, platform: platform)
        }

        return PaginatedBrowse.merge(siteName: displayName, batches: batches)
    }

    /// Catégorie Jtag/RGH (id 113) — ~5481 titres ; la page « list all » JTAG est vide.
    private func browseJTAGREST() async throws -> [GameResult] {
        return try await PaginatedBrowse.collect(through: maxJTAGPages, siteName: displayName) { page in
            var components = URLComponents(string: "\(listHost)/wp-json/wp/v2/posts")!
            components.queryItems = [
                URLQueryItem(name: "categories", value: "113"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components.url else { return [] }

            let json = try await HTTPClient.fetchJSON(from: url, timeout: 30)
            guard let posts = json as? [[String: Any]] else { return [] }
            return posts.compactMap { parseRESTPost($0, platform: .x360) }
        }
    }

    // MARK: - Search

    private func searchHTML(_ query: String, platform: Platform) async throws -> [GameResult] {
        var components = URLComponents(string: "\(listHost)/")!
        components.queryItems = [URLQueryItem(name: "s", value: query)]
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        return parseSearchResults(html: html).filter { matchesPlatform($0, platform: platform) }
    }

    // MARK: - Parse

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

            let platform = detectPlatform(from: pageURL, title: title) ?? .x360
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

        let title = cleanTitle(HTMLParser.decodeEntities(titleRendered))
        guard title.count > 1 else { return nil }

        return GameResult(
            title: title,
            platform: platform,
            sourceSite: displayName,
            pageURL: pageURL,
            regionHint: pageURL.lastPathComponent
        )
    }

    private func matchesPlatform(_ result: GameResult, platform: Platform) -> Bool {
        result.platform == platform
            || detectPlatform(from: result.pageURL, title: result.title) == platform
    }

    private func detectPlatform(from url: URL, title: String) -> Platform? {
        let path = url.path.lowercased()
        let t = title.lowercased()
        if path.contains("xbox-classic") || t.contains("xbox classic") { return .xbox }
        if path.contains("jtag") || path.contains("rgh") || path.contains("-iso")
            || t.contains("jtag") || t.contains("[iso]") || path.contains("xbla") {
            return .x360
        }
        if path.contains("xbox") { return .x360 }
        return nil
    }

    private func isGamePostURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host.contains("downloadgamexbox") || host.contains("dlxbgame") else { return false }
        let path = url.path.lowercased()
        let blocked = ["/category/", "/tag/", "/page/", "/wp-", "/list-", "/dmca", "/guide", "/feed"]
        if blocked.contains(where: { path.contains($0) }) { return false }
        return url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count > 2
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = raw
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        for pattern in [
            #"\s*\[.*?\]\s*"#,
            #"\s*[-–|].*$"#,
            #"™|®"#
        ] {
            title = title.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return title
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dedupe(_ results: [GameResult]) -> [GameResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.pageURL.absoluteString).inserted }
    }
}
