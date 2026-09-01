import Foundation

/// CoolROM — souvent indisponible (retrait droits d’auteur sur coolrom.com).
/// L’adapter tente coolrom.com puis coolrom.com.au ; échec soft si listing absent.
struct CoolROMAdapter: SiteAdapter {
    let id = "coolrom"
    let displayName = "CoolROM"
    private let hosts = ["https://coolrom.com", "https://coolrom.com.au"]
    private let maxBrowsePages = 30

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform, platform.coolROMSystem == nil {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        for host in hosts {
            var components = URLComponents(string: "\(host)/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            guard let url = components.url else { continue }

            guard let html = try? await HTTPClient.fetchString(from: url) else { continue }
            let all = parse(html: html, baseHost: host)
            guard !all.isEmpty else { continue }

            guard let platform else { return all }
            return all.filter { $0.platform == platform }
        }

        return []
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let system = platform.coolROMSystem else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        for host in hosts {
            let all = (try? await PaginatedBrowse.collect(through: maxBrowsePages, siteName: displayName) { page in
                let url: URL
                if page == 1 {
                    guard let u = URL(string: "\(host)/roms/\(system)/") else { return [] }
                    url = u
                } else {
                    guard let u = URL(string: "\(host)/roms/\(system)/?page=\(page)") else { return [] }
                    url = u
                }

                let html = try await HTTPClient.fetchString(from: url)
                if html.localizedCaseInsensitiveContains("Removed Due to Copyrights") { return [] }
                return parseListing(html: html, platform: platform, system: system, baseHost: host)
            }) ?? []

            if !all.isEmpty { return all }
        }

        return []
    }

    private func parse(html: String, baseHost: String) -> [GameResult] {
        let pattern = #"<a href="(?:https?://(?:www\.)?coolrom\.com(?:\.au)?)?(/roms/([a-z0-9-]+)/\d+/[^"]+\.html)"[^>]*>\s*([^<]+)</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []
        let baseURL = URL(string: baseHost)!

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = match.groups[0]
            let system = match.groups[1]
            let title = HTMLParser.decodeEntities(match.groups[2])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }

            let platform = Platform.allCases.first { $0.coolROMSystem == system } ?? .snes
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

    private func parseListing(html: String, platform: Platform, system: String, baseHost: String) -> [GameResult] {
        let escapedSystem = NSRegularExpression.escapedPattern(for: system)
        let pattern = #"<a href="(?:https?://(?:www\.)?coolrom\.com(?:\.au)?)?(/roms/\#(escapedSystem)/\d+/[^"]+\.html)"[^>]*(?:title="([^"]*)")?[^>]*>\s*([^<]+)\s*</a>"#
            .replacingOccurrences(of: "#(escapedSystem)", with: escapedSystem)

        var seen = Set<String>()
        var results: [GameResult] = []
        let baseURL = URL(string: baseHost)!

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = match.groups[0]
            var title = HTMLParser.decodeEntities(match.groups.count > 2 ? match.groups[2] : match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty, match.groups.count > 1 {
                title = HTMLParser.decodeEntities(match.groups[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
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

        if results.isEmpty {
            return parse(html: html, baseHost: baseHost).filter { $0.platform == platform }
        }

        return results
    }
}

extension Platform {
    var coolROMSystem: String? {
        switch self {
        case .gb: return "gameboy"
        case .gbc: return "gameboyc"
        case .gba: return "gameboya"
        case .nds: return "nds"
        case .n3ds: return "3ds"
        case .nes: return "nes"
        case .snes: return "snes"
        case .n64: return "n64"
        case .gameCube: return "gamecube"
        case .wii: return "wii"
        case .wiiU: return "wiiu"
        case .switchPlatform: return nil
        case .ps1: return "psx"
        case .ps2: return "ps2"
        case .ps3: return "ps3"
        case .psp: return "psp"
        case .xbox: return "xbox"
        case .x360: return "xbox360"
        case .dreamcast: return "dreamcast"
        case .mame: return "mame"
        }
    }
}
