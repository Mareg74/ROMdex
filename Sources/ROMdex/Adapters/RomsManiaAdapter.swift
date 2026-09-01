import Foundation

/// RomsMania (romsmania.games) — anciennement romsmania.cc.
struct RomsManiaAdapter: SiteAdapter {
    let id = "romsmania"
    let displayName = "RomsMania"
    private let baseURL = URL(string: "https://romsmania.games")!
    private let maxBrowsePages = 40

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.romsManiaSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        return try await PaginatedBrowse.collect(through: maxBrowsePages, siteName: displayName) { page in
            let path = page == 1 ? "/\(slug)/" : "/\(slug)/page/\(page)/"
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return [] }

            let html = try await HTTPClient.fetchString(from: url)
            return parseListing(html: html, platform: platform, slug: slug)
        }
    }

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let slug = trimmed.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty,
              let url = URL(string: "/search/\(slug)/", relativeTo: baseURL)?.absoluteURL else {
            return []
        }

        let html: String
        do {
            html = try await HTTPClient.fetchString(from: url)
        } catch {
            return []
        }

        return parseSearchResults(html: html, platformFilter: platform)
    }

    private func parseListing(html: String, platform: Platform, slug: String) -> [GameResult] {
        parseGameLinks(in: html, slugFilter: slug).map { link in
            GameResult(
                title: link.title,
                platform: platform,
                sourceSite: displayName,
                pageURL: link.pageURL,
                regionHint: link.path
            )
        }
    }

    private func parseSearchResults(html: String, platformFilter: Platform?) -> [GameResult] {
        var seen = Set<String>()
        var results: [GameResult] = []

        for link in parseGameLinks(in: html, slugFilter: nil) {
            guard seen.insert(link.pageURL.absoluteString).inserted else { continue }
            guard let resolved = Platform.platform(forRomsManiaSlug: link.slug) else { continue }
            if let platformFilter, resolved != platformFilter { continue }

            results.append(
                GameResult(
                    title: link.title,
                    platform: resolved,
                    sourceSite: displayName,
                    pageURL: link.pageURL,
                    regionHint: link.path
                )
            )
        }
        return results
    }

    private struct ParsedLink {
        let slug: String
        let path: String
        let pageURL: URL
        let title: String
    }

    /// Liens jeu : `/{console}/{jeu}/` avec titre dans `<span class="title">`.
    private func parseGameLinks(in html: String, slugFilter: String?) -> [ParsedLink] {
        let slugPattern: String
        if let slugFilter {
            slugPattern = NSRegularExpression.escapedPattern(for: slugFilter)
        } else {
            slugPattern = "[a-z0-9-]+"
        }

        let pattern = #"<a href="(?:https://(?:www\.)?romsmania\.games)?/(#(slugPattern)/([^"/]+)/"[^>]*>[\s\S]*?<span class="title">\s*([^<]+?)\s*</span>"#
            .replacingOccurrences(of: "#(slugPattern)", with: slugPattern)

        var seen = Set<String>()
        var links: [ParsedLink] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let slug = match.groups[0]
            let gameSlug = match.groups[1]
            let title = HTMLParser.decodeEntities(match.groups[2])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let path = "/\(slug)/\(gameSlug)/"
            guard !title.isEmpty, let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            links.append(
                ParsedLink(slug: slug, path: path, pageURL: pageURL, title: title)
            )
        }
        return links
    }
}

extension Platform {
    var romsManiaSlug: String? {
        switch self {
        case .gbc: return "game-boy-color"
        case .gba: return "game-boy-advance"
        case .nds: return "nintendo-ds"
        case .n3ds: return "3ds"
        case .n64: return "nintendo-64"
        case .gameCube: return "gamecube"
        case .wii: return "wii"
        case .wiiU: return "wiiu"
        case .switchPlatform: return "switch"
        case .ps1: return "playstation"
        case .ps2: return "playstation-2"
        case .ps3: return "playstation-3"
        case .psp: return "psp"
        case .xbox: return "xbox"
        case .x360: return "xbox-360"
        case .dreamcast: return "dreamcast"
        case .gb, .nes, .snes, .mame:
            return nil
        }
    }

    static func platform(forRomsManiaSlug slug: String) -> Platform? {
        allCases.first { $0.romsManiaSlug == slug }
    }
}
