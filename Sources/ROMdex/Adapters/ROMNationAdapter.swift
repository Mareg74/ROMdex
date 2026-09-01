import Foundation

/// ROMNation est souvent hors ligne. Échec soft.
struct ROMNationAdapter: SiteAdapter {
    let id = "romnation"
    let displayName = "ROMNation"
    private let baseURL = URL(string: "https://romnation.net")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let candidates = [
            "https://romnation.net/searchRom.php",
            "https://www.romnation.net/searchRom.php",
            "https://romnation.net/roms/search"
        ]

        for base in candidates {
            var components = URLComponents(string: base)!
            components.queryItems = [
                URLQueryItem(name: "name", value: trimmed),
                URLQueryItem(name: "q", value: trimmed)
            ]
            guard let url = components.url else { continue }

            guard let html = try? await HTTPClient.fetchString(from: url), html.count > 800 else {
                continue
            }

            let parsed = parse(html: html, platform: platform)
            if !parsed.isEmpty { return parsed }
        }

        return []
    }

    private func parse(html: String, platform: Platform?) -> [GameResult] {
        let pattern = #"<a href="(?:https://(?:www\.)?romnation\.net)?(/rom/[^"]+|/roms/[^"]+)"[^>]*>\s*([^<]+)</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 1, let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: platform ?? .snes,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: path
                )
            )
        }

        return results
    }
}
