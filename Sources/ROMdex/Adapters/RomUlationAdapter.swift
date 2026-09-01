import Foundation

struct RomUlationAdapter: SiteAdapter {
    let id = "romulation"
    let displayName = "RomUlation"
    private let baseURL = URL(string: "https://www.romulation.org")!
    private static var sitemapCache: String?
    private static let alphabetFallback = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    func browse(platform: Platform) async throws -> [GameResult] {
        guard platform.romUlationSystem != nil else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var results: [GameResult] = []
        if let segment = platform.romUlationSitemapSegment {
            results = try await browseFromSitemap(platform: platform, segment: segment)
        }
        if results.isEmpty {
            results = try await browseFromAlphabetSearch(platform: platform)
        }

        CatalogBrowseProgress.reportGames(site: displayName, results)
        return results
    }

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.romulation.org/roms/search")!
        var items = [URLQueryItem(name: "query", value: trimmed)]
        if let platform, let system = platform.romUlationSystem {
            items.append(URLQueryItem(name: "system", value: system))
        } else if let platform {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        let all = parse(html: html)
        let filtered: [GameResult]
        if let platform {
            filtered = all.filter { $0.platform == platform }
        } else {
            filtered = all
        }

        return await enrichCovers(filtered)
    }

    // MARK: - Browse

    private func browseFromSitemap(platform: Platform, segment: String) async throws -> [GameResult] {
        let xml = try await fetchSitemap()
        let escaped = NSRegularExpression.escapedPattern(for: segment)
        let pattern = #"<loc>https://www\.romulation\.org/rom/\#(escaped)/([^<]+)</loc>"#
            .replacingOccurrences(of: "#(escaped)", with: escaped)

        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: xml, pattern: pattern) {
            let slug = match.groups[0]
            guard let pageURL = URL(string: "https://www.romulation.org/rom/\(segment)/\(slug)") else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            let title = titleFromRomSlug(slug)
            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: slug
                )
            )
        }
        return results
    }

    private func browseFromAlphabetSearch(platform: Platform) async throws -> [GameResult] {
        guard let system = platform.romUlationSystem else { return [] }

        let batches = await ParallelFetch.mapOptional(Self.alphabetFallback) { char -> [GameResult]? in
            var components = URLComponents(string: "https://www.romulation.org/roms/search")!
            components.queryItems = [
                URLQueryItem(name: "query", value: String(char)),
                URLQueryItem(name: "system", value: system)
            ]
            guard let url = components.url else { return nil }
            guard let html = try? await HTTPClient.fetchString(from: url) else { return nil }
            return parse(html: html).filter { $0.platform == platform }
        }

        return PaginatedBrowse.merge(siteName: displayName, batches: batches)
    }

    private func fetchSitemap() async throws -> String {
        if let cached = Self.sitemapCache { return cached }
        guard let url = URL(string: "https://www.romulation.org/sitemap.xml") else {
            throw SiteAdapterError.invalidResponse
        }
        let xml = try await HTTPClient.fetchString(from: url, timeout: 60)
        Self.sitemapCache = xml
        return xml
    }

    private func titleFromRomSlug(_ slug: String) -> String {
        let decoded = slug.removingPercentEncoding ?? slug
        var title = decoded
        if let dash = title.firstIndex(of: "-") {
            title = String(title[title.index(after: dash)...])
        }
        title = title.replacingOccurrences(of: "-", with: " ")
        if let paren = title.range(of: #"\([^)]*\)$"#, options: .regularExpression) {
            title.removeSubrange(paren)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parse(html: String) -> [GameResult] {
        let rowPattern = #"<tr>[\s\S]*?<span class="(flags-[a-z]+)">[^<]*</span>[\s\S]*?<a href="(/rom/([A-Za-z0-9+-]+)/[^"]+)"[^>]*>\s*(?:\[[^\]]+\]\s*)?([^<]+)</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        let matches = HTMLParser.matches(in: html, pattern: rowPattern)
        if !matches.isEmpty {
            for match in matches {
                let flagClass = match.groups[0]
                let path = match.groups[1]
                let system = match.groups[2]
                let title = cleanTitle(match.groups[3])
                guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
                guard seen.insert(url.absoluteString).inserted else { continue }

                guard let platform = Platform.fromRomUlationPath(system) else { continue }

                results.append(
                    GameResult(
                        title: title,
                        platform: platform,
                        sourceSite: displayName,
                        pageURL: url,
                        regionHint: flagClass
                    )
                )
            }
            return results
        }

        let linkPattern = #"<a href="(/rom/([A-Za-z0-9+-]+)/[^"]+)"[^>]*>\s*(?:\[[^\]]+\]\s*)?([^<]+)</a>"#
        for match in HTMLParser.matches(in: html, pattern: linkPattern) {
            let path = match.groups[0]
            let system = match.groups[1]
            let title = cleanTitle(match.groups[2])
            guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }

            guard let platform = Platform.fromRomUlationPath(system) else { continue }

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

        return results
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = HTMLParser.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = title.range(of: #"^\[[^\]]+\]\s*"#, options: .regularExpression) {
            title.removeSubrange(bracket)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enrichCovers(_ results: [GameResult]) async -> [GameResult] {
        guard !results.isEmpty else { return results }

        let covers = await withTaskGroup(of: (URL, URL?).self) { group in
            for result in results.prefix(30) {
                group.addTask {
                    (result.pageURL, await self.fetchCover(from: result.pageURL))
                }
            }

            var map: [URL: URL] = [:]
            for await (page, cover) in group {
                if let cover { map[page] = cover }
            }
            return map
        }

        guard !covers.isEmpty else { return results }

        return results.map { result in
            guard let thumb = covers[result.pageURL] else { return result }
            return result.updatingThumbnail(thumb, forPageURL: result.pageURL)
        }
    }

    private func fetchCover(from url: URL) async -> URL? {
        guard let html = try? await HTTPClient.fetchString(from: url) else { return nil }

        // Première capture d’écran du jeu (pas de box art dédiée sur ces fiches).
        let shot = #"(https://www\.romulation\.org/media/img/screenshots/[^"'\s]+\.(?:png|jpg|jpeg|webp))"#
        if let match = HTMLParser.matches(in: html, pattern: shot).first,
           let cover = URL(string: match.groups[0]) {
            return cover
        }

        let relative = #"src="(/media/img/screenshots/[^"]+)""#
        if let match = HTMLParser.matches(in: html, pattern: relative).first,
           let cover = HTTPClient.absoluteURL(match.groups[0], base: baseURL) {
            return cover
        }

        return nil
    }
}

extension Platform {
    var romUlationSystem: String? {
        switch self {
        case .gb: return "GB"
        case .gbc: return "GBC"
        case .gba: return "GBA"
        case .nds: return "NDS"
        case .n3ds: return "3DS"
        case .nes: return "NES"
        case .snes: return "SNES"
        case .n64: return "N64"
        case .gameCube: return "GC"
        case .wii: return "WII"
        case .wiiU: return "WIIU"
        case .switchPlatform: return "SWITCH"
        case .ps1: return "PS1"
        case .ps2: return "PS2"
        case .ps3: return "PS3"
        case .psp: return "PSP"
        case .xbox: return "XBOX"
        case .x360: return "X360"
        case .dreamcast: return "DC"
        case .mame: return "MAME"
        }
    }

    /// Segment chemin `/rom/{segment}/` dans le sitemap RomUlation.
    var romUlationSitemapSegment: String? {
        switch self {
        case .gba: return "GBA"
        case .nds: return "NDS"
        case .n3ds: return "3DS"
        case .n64: return "N64"
        case .gameCube: return "GameCube"
        case .wii: return "Wii"
        case .ps1: return "PSX"
        case .ps2: return "PS2"
        case .ps3: return "PS3"
        case .psp: return "PSP"
        case .xbox: return "XBOX"
        case .dreamcast: return "Dreamcast"
        default: return nil
        }
    }

    static func fromRomUlationPath(_ segment: String) -> Platform? {
        if let match = allCases.first(where: {
            $0.romUlationSitemapSegment?.caseInsensitiveCompare(segment) == .orderedSame
                || $0.romUlationSystem?.caseInsensitiveCompare(segment) == .orderedSame
        }) {
            return match
        }
        switch segment {
        case "PSX": return .ps1
        case "GameCube": return .gameCube
        case "Wii": return .wii
        case "XBOX": return .xbox
        case "Dreamcast": return .dreamcast
        case "Game_Boy_Color": return .gbc
        default: return nil
        }
    }
}
