import Foundation

/// Gamulator est souvent indisponible (Cloudflare 530). Échec soft.
struct GamulatorAdapter: SiteAdapter {
    let id = "gamulator"
    let displayName = "Gamulator"
    private let baseURL = URL(string: "https://www.gamulator.com")!
    private let maxBrowsePages = 40

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.gamulatorSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        return try await PaginatedBrowse.collect(through: maxBrowsePages, siteName: displayName) { page in
            let url: URL
            if page == 1 {
                guard let u = URL(string: "https://www.gamulator.com/roms/\(slug)/") else { return [] }
                url = u
            } else {
                guard let u = URL(string: "https://www.gamulator.com/roms/\(slug)/page/\(page)/") else { return [] }
                url = u
            }

            let html = try await HTTPClient.fetchString(from: url)
            return parseListing(html: html, platform: platform, slug: slug)
        }
    }

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.gamulator.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { return [] }

        let html: String
        do {
            html = try await HTTPClient.fetchString(from: url)
        } catch {
            return []
        }

        let pattern = #"<a href="(?:https://(?:www\.)?gamulator\.com)?(/roms/([a-z0-9-]+)/[^"]+)"[^>]*>\s*([^<]+)</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = match.groups[0]
            let slug = match.groups[1]
            let title = HTMLParser.decodeEntities(match.groups[2])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            let resolved = Platform.allCases.first { $0.gamulatorSlug == slug } ?? platform ?? .snes
            if let platform, resolved != platform { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: resolved,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: path
                )
            )
        }

        return results
    }

    private func parseListing(html: String, platform: Platform, slug: String) -> [GameResult] {
        let escaped = NSRegularExpression.escapedPattern(for: slug)
        let pattern = #"<a href="(?:https://(?:www\.)?gamulator\.com)?(/roms/\#(escaped)/[^"]+)"[^>]*>\s*([^<]+)</a>"#
            .replacingOccurrences(of: "#(escaped)", with: escaped)

        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: path
                )
            )
        }
        return results
    }
}

extension Platform {
    var gamulatorSlug: String? {
        switch self {
        case .gb: return "gameboy"
        case .gbc: return "gameboy-color"
        case .gba: return "gameboy-advance"
        case .nds: return "nintendo-ds"
        case .n3ds: return "nintendo-3ds"
        case .nes: return "nes"
        case .snes: return "super-nintendo"
        case .n64: return "nintendo-64"
        case .gameCube: return "gamecube"
        case .wii: return "wii"
        case .wiiU: return "wii-u"
        case .switchPlatform: return "nintendo-switch"
        case .ps1: return "playstation"
        case .ps2: return "playstation-2"
        case .ps3: return "playstation-3"
        case .psp: return "psp"
        case .xbox: return "xbox"
        case .x360: return "xbox-360"
        case .dreamcast: return "dreamcast"
        case .mame: return "mame"
        }
    }
}
