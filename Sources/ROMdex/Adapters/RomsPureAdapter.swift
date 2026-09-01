import Foundation

/// RomsPure — listing WordPress (`/roms/{slug}/`). Protégé Cloudflare → `BrowserHTMLClient`.
struct RomsPureAdapter: SiteAdapter {
    let id = "romspure"
    let displayName = "RomsPure"
    private let baseURL = URL(string: "https://romspure.cc")!
    private let maxBrowsePages = 120

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            guard platform.romsPureSlug != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            return try await searchOnPlatform(trimmed, platform: platform)
        }

        let platforms = Platform.allCases.filter { $0.romsPureSlug != nil }
        let merged = await ParallelFetch.map(Array(platforms.prefix(8))) { platform in
            (try? await self.searchOnPlatform(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
        return dedupe(merged)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.romsPureSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let page1 = try await fetchBrowsePage(platform: platform, slug: slug, page: 1)
        var maxPage = maxBrowsePages
        let detected = detectedMaxPage(in: page1.html, slug: slug)
        if detected > 1 {
            maxPage = min(maxBrowsePages, detected)
        }

        if maxPage <= 1 {
            CatalogBrowseProgress.reportGames(site: displayName, page1.games)
            return page1.games
        }

        let rest = await ParallelFetch.mapOptional(Array(2 ... maxPage)) { page -> [GameResult]? in
            guard let batch = try? await fetchBrowsePage(platform: platform, slug: slug, page: page) else { return nil }
            return batch.games
        }

        return PaginatedBrowse.merge(siteName: displayName, batches: [page1.games] + rest)
    }

    // MARK: - Fetch

    private func searchOnPlatform(_ query: String, platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.romsPureSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://romspure.cc/roms/\(slug)/")!
        components.queryItems = [URLQueryItem(name: "s", value: query)]
        guard let url = components.url else { return [] }

        let html = try await fetchHTML(url)
        let fromSearch = parse(html: html, platform: platform, slug: slug)
        let needle = query.lowercased()
        let filtered = fromSearch.filter {
            $0.title.lowercased().contains(needle)
                || $0.pageURL.lastPathComponent.lowercased().contains(needle.replacingOccurrences(of: " ", with: "-"))
        }
        if !filtered.isEmpty { return filtered }

        let listing = try await fetchBrowsePage(platform: platform, slug: slug, page: 1).games
        return listing.filter {
            $0.title.lowercased().contains(needle)
                || $0.pageURL.lastPathComponent.lowercased().contains(needle.replacingOccurrences(of: " ", with: "-"))
        }
    }

    private func fetchBrowsePage(platform: Platform, slug: String, page: Int) async throws -> (games: [GameResult], html: String) {
        let url: URL
        if page <= 1 {
            guard let u = URL(string: "https://romspure.cc/roms/\(slug)/") else {
                return ([], "")
            }
            url = u
        } else {
            guard let u = URL(string: "https://romspure.cc/roms/\(slug)/page/\(page)/") else {
                return ([], "")
            }
            url = u
        }

        let html = try await fetchHTML(url)
        return (parse(html: html, platform: platform, slug: slug), html)
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        let html = try await BrowserHTMLClient.shared.fetchHTML(from: url)
        if isCloudflareBlockPage(html) {
            throw SiteAdapterError.blocked(displayName)
        }
        return html
    }

    /// Détection CF sans `@MainActor` (contrairement à `BrowserHTMLClient.isCloudflareChallenge`).
    private func isCloudflareBlockPage(_ html: String) -> Bool {
        let h = html.lowercased()
        if h.contains("cdn-cgi/challenge-platform") { return true }
        if h.contains("just a moment") && h.contains("cloudflare") { return true }
        if h.contains("enable javascript and cookies to continue") { return true }
        return false
    }

    // MARK: - Parse

    private func parse(html: String, platform: Platform, slug: String) -> [GameResult] {
        if isCloudflareBlockPage(html) { return [] }

        let escapedSlug = NSRegularExpression.escapedPattern(for: slug)
        let pathPattern = "/roms/\(escapedSlug)/([a-z0-9][a-z0-9-]*)/"
        let thumbPathPattern = "/roms/\(escapedSlug)/[a-z0-9][a-z0-9-]*/"

        let thumbs = CoverArtParser.thumbnails(
            in: html,
            pathPattern: thumbPathPattern,
            imagePattern: #"(?:https://romspure\.cc)?/wp-content/uploads/[^"'\s]+\.(?:png|jpe?g|webp)"#,
            baseURL: baseURL
        )

        var titlesByPath: [String: String] = [:]

        let titleAfterHref =
            #"<a[^>]+href="((?:https://romspure\.cc)?"# + pathPattern + #")"[\s\S]{0,400}?<(?:h2|h3)[^>]*>\s*([^<]+?)\s*</(?:h2|h3)>"#
        for match in HTMLParser.matches(in: html, pattern: titleAfterHref) {
            let path = normalizePath(match.groups[0])
            let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titlesByPath[path] = title }
        }

        let titleInsideHeading =
            #"<(?:h2|h3)[^>]*>\s*<a[^>]+href="((?:https://romspure\.cc)?"# + pathPattern + #")"[^>]*>\s*([^<]+?)\s*</a>"#
        for match in HTMLParser.matches(in: html, pattern: titleInsideHeading) {
            let path = normalizePath(match.groups[0])
            let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titlesByPath[path] = title }
        }

        var seen = Set<String>()
        var results: [GameResult] = []

        let linkOnly = #"href="((?:https://romspure\.cc)?"# + pathPattern + #")""#
        for match in HTMLParser.matches(in: html, pattern: linkOnly) {
            let path = normalizePath(match.groups[0])
            let gameSlug = match.groups[1]
            guard !gameSlug.isEmpty, gameSlug != "page" else { continue }
            guard let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }

            let title = titlesByPath[path]
                ?? gameSlug
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: url,
                    thumbnailURL: {
                        let candidate = thumbs[path] ?? thumbs[url.path]
                        return CoverArtParser.isUsableCover(candidate) ? candidate : nil
                    }(),
                    regionHint: gameSlug
                )
            )
        }

        return results
    }

    private func detectedMaxPage(in html: String, slug: String) -> Int {
        let escapedSlug = NSRegularExpression.escapedPattern(for: slug)
        let pattern = "/roms/\(escapedSlug)/page/(\\d+)/?"
        let pages = HTMLParser.matches(in: html, pattern: pattern).compactMap { Int($0.groups[0]) }
        return pages.max() ?? 1
    }

    private func normalizePath(_ href: String) -> String {
        if href.hasPrefix("http"), let url = URL(string: href) {
            var path = url.path
            if !path.hasSuffix("/") { path += "/" }
            return path
        }
        var path = href
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    private func dedupe(_ results: [GameResult]) -> [GameResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.pageURL.absoluteString).inserted }
    }
}

extension Platform {
    /// Slug listing RomsPure (`/roms/{slug}/`). `nil` = non supporté.
    var romsPureSlug: String? {
        switch self {
        case .gb: return "nintendo-game-boy"
        case .gbc: return "nintendo-game-boy-color"
        case .gba: return "nintendo-game-boy-advance"
        case .nds: return "nintendo-ds"
        case .n3ds: return "nintendo-3ds"
        case .nes: return "nes"
        case .snes: return "super-nintendo-entertainment-system"
        case .n64: return "nintendo-64"
        case .gameCube: return "nintendo-gamecube"
        case .wii: return "nintendo-wii"
        case .wiiU: return "nintendo-wii-u"
        case .switchPlatform: return nil
        case .ps1: return "sony-playstation"
        case .ps2: return "sony-playstation-2"
        case .ps3: return "sony-playstation-3"
        case .psp: return "sony-psp"
        case .xbox: return "xbox"
        case .x360: return "xbox-360"
        case .dreamcast: return "sega-dreamcast"
        case .mame: return "mame"
        }
    }
}
