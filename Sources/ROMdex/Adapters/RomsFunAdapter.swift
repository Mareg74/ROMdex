import Foundation

/// RomsFun — catalogue large (Wii U ~842, etc.). Les pages sont protégées par Cloudflare :
/// le HTML est récupéré via `BrowserHTMLClient` (WKWebView), pas `URLSession`.
struct RomsFunAdapter: SiteAdapter {
    let id = "romsfun"
    let displayName = "RomsFun"
    private let baseURL = URL(string: "https://romsfun.com")!
    /// Pages max par console (NDS/PS2 RomsFun = plusieurs milliers de jeux).
    private let maxBrowsePages = 400

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform {
            guard platform.romsFunSlug != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            return try await searchOnPlatform(trimmed, platform: platform)
        }

        let platforms = Platform.allCases.filter { $0.romsFunSlug != nil }
        let merged = await ParallelFetch.map(Array(platforms.prefix(8))) { platform in
            (try? await self.searchOnPlatform(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
        return dedupe(merged)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.romsFunSlug else {
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
        guard let slug = platform.romsFunSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://romsfun.com/roms/\(slug)/")!
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

        // Fallback : première page listing + filtre local.
        let listing = try await fetchBrowsePage(platform: platform, slug: slug, page: 1).games
        return listing.filter {
            $0.title.lowercased().contains(needle)
                || $0.pageURL.lastPathComponent.lowercased().contains(needle.replacingOccurrences(of: " ", with: "-"))
        }
    }

    private func fetchBrowsePage(platform: Platform, slug: String, page: Int) async throws -> (games: [GameResult], html: String) {
        let url: URL
        if page <= 1 {
            guard let u = URL(string: "https://romsfun.com/roms/\(slug)/") else {
                return ([], "")
            }
            url = u
        } else {
            guard let u = URL(string: "https://romsfun.com/roms/\(slug)/page/\(page)/") else {
                return ([], "")
            }
            url = u
        }

        let listing = try await BrowserHTMLClient.shared.fetchRomsFunListing(from: url)
        return (parse(html: listing.html, platform: platform, slug: slug, domThumbs: listing.thumbs), listing.html)
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        try await BrowserHTMLClient.shared.fetchHTML(from: url)
    }

    // MARK: - Parse

    private func parse(
        html: String,
        platform: Platform,
        slug: String,
        domThumbs: [String: URL] = [:]
    ) -> [GameResult] {
        let escapedSlug = NSRegularExpression.escapedPattern(for: slug)
        // Groupe capturant pour le parse des liens ; pattern sans capture pour les jaquettes.
        let pathPattern = "/roms/\(escapedSlug)/([a-z0-9][a-z0-9-]*)\\.html"
        let thumbPathPattern = "/roms/\(escapedSlug)/[a-z0-9][a-z0-9-]*\\.html"

        var thumbs = CoverArtParser.thumbnails(
            in: html,
            pathPattern: thumbPathPattern,
            imagePattern: #"(?:https://romsfun\.com)?/wp-content/uploads/[^"'\s]+\.(?:png|jpe?g|webp)"#,
            baseURL: baseURL
        )
        for (path, url) in domThumbs {
            if thumbs[path] == nil {
                thumbs[path] = url
            }
        }

        var titlesByPath: [String: String] = [:]

        // <a href="...html"> <h2|h3>Title</h2|h3>
        let titleAfterHref =
            #"<a[^>]+href="((?:https://romsfun\.com)?"# + pathPattern + #")"[\s\S]{0,400}?<(?:h2|h3)[^>]*>\s*([^<]+?)\s*</(?:h2|h3)>"#
        for match in HTMLParser.matches(in: html, pattern: titleAfterHref) {
            let path = normalizePath(match.groups[0])
            let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titlesByPath[path] = title }
        }

        // <h2|h3><a href="...html">Title</a>
        let titleInsideHeading =
            #"<(?:h2|h3)[^>]*>\s*<a[^>]+href="((?:https://romsfun\.com)?"# + pathPattern + #")"[^>]*>\s*([^<]+?)\s*</a>"#
        for match in HTMLParser.matches(in: html, pattern: titleInsideHeading) {
            let path = normalizePath(match.groups[0])
            let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titlesByPath[path] = title }
        }

        // Lien seul avec texte.
        let linkText =
            #"<a[^>]+href="((?:https://romsfun\.com)?"# + pathPattern + #")"[^>]*>\s*([^<]{2,120}?)\s*</a>"#
        for match in HTMLParser.matches(in: html, pattern: linkText) {
            let path = normalizePath(match.groups[0])
            guard titlesByPath[path] == nil else { continue }
            let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = title.lowercased()
            guard !title.isEmpty,
                  !lower.contains("download"),
                  !lower.contains("emulator"),
                  !lower.hasPrefix("http") else { continue }
            titlesByPath[path] = title
        }

        var seen = Set<String>()
        var results: [GameResult] = []

        let linkOnly = #"href="((?:https://romsfun\.com)?"# + pathPattern + #")""#
        for match in HTMLParser.matches(in: html, pattern: linkOnly) {
            let path = normalizePath(match.groups[0])
            let gameSlug = match.groups[1]
            guard gameSlug != "page", !gameSlug.isEmpty else { continue }
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
        if let url = URL(string: href), url.host != nil {
            return url.path
        }
        if href.hasPrefix("http") {
            return URL(string: href)?.path ?? href
        }
        return href
    }

    private func dedupe(_ results: [GameResult]) -> [GameResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.pageURL.absoluteString).inserted }
    }
}

extension Platform {
    /// Slug listing RomsFun (`/roms/{slug}/`). `nil` = non supporté (ex. MAME).
    var romsFunSlug: String? {
        switch self {
        case .gb: return "game-boy"
        case .gbc: return "game-boy-color"
        case .gba: return "game-boy-advance"
        case .nds: return "nintendo-ds"
        case .n3ds: return "nintendo-3ds"
        case .nes: return "nes"
        case .snes: return "super-nintendo"
        case .n64: return "nintendo-64"
        case .gameCube: return "gamecube"
        case .wii: return "nintendo-wii"
        case .wiiU: return "wii-u"
        case .switchPlatform: return "nintendo-switch"
        case .ps1: return "playstation"
        case .ps2: return "playstation-2"
        case .ps3: return "playstation-3"
        case .psp: return "playstation-portable"
        case .xbox: return "xbox"
        case .x360: return "xbox-360"
        case .dreamcast: return "dreamcast"
        case .mame: return nil // Pas de listing arcade/MAME fiable sur RomsFun
        }
    }
}
