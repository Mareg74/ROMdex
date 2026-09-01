import Foundation

/// DopeROMS redirige souvent vers un lander publicitaire — échec soft si pas de résultats utiles.
struct DopeROMSAdapter: SiteAdapter {
    let id = "doperoms"
    let displayName = "DopeROMS"

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.doperoms.com/")!
        components.queryItems = [URLQueryItem(name: "s", value: trimmed)]
        guard let url = components.url else { return [] }

        let html: String
        do {
            html = try await HTTPClient.fetchString(from: url)
        } catch {
            return []
        }

        if html.localizedCaseInsensitiveContains("lander") || html.count < 500 {
            return []
        }

        let pattern = #"<a href="(https://(?:www\.)?doperoms\.com/[^"]+)"[^>]*>\s*([^<]{2,120})</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let link = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.localizedCaseInsensitiveContains(trimmed) else { continue }
            guard let pageURL = URL(string: link) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            let resolved = platform ?? .snes
            results.append(
                GameResult(
                    title: title,
                    platform: resolved,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: link
                )
            )
        }

        return results
    }
}
