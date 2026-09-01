import Foundation

/// LostROMs redirige vers Old Games Download — on indexe ce successeur.
struct LostROMsAdapter: SiteAdapter {
    let id = "lostroms"
    let displayName = "LostROMs"
    private let baseURL = URL(string: "https://oldgamesdownload.com")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://oldgamesdownload.com/")!
        components.queryItems = [URLQueryItem(name: "s", value: trimmed)]
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        return parse(html: html, platform: platform)
    }

    private func parse(html: String, platform: Platform?) -> [GameResult] {
        let articlePattern = #"<article[^>]*class="([^"]*)"[^>]*>[\s\S]*?<a[^>]+href="(https://oldgamesdownload\.com/([a-z0-9-]+)/)"[^>]*>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        let matches = HTMLParser.matches(in: html, pattern: articlePattern)
        if !matches.isEmpty {
            for match in matches {
                let classes = match.groups[0]
                let link = match.groups[1]
                let slug = match.groups[2]
                guard let pageURL = URL(string: link) else { continue }
                guard seen.insert(pageURL.absoluteString).inserted else { continue }

                let title = titleFromSlug(slug)
                let resolved = platformFromCategories(classes) ?? platform ?? .snes
                if let platform, resolved != platform, platformFromCategories(classes) != nil {
                    continue
                }

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

        let linkPattern = #"<a[^>]+href="(https://oldgamesdownload\.com/([a-z0-9-]+)/)"[^>]*>"#
        for match in HTMLParser.matches(in: html, pattern: linkPattern) {
            let link = match.groups[0]
            let slug = match.groups[1]
            let skip: Set<String> = [
                "wiki", "request", "missing-games", "about", "faq", "contact",
                "privacy-policy", "cookies-policy", "browse"
            ]
            guard !skip.contains(slug), !slug.hasPrefix("browse") else { continue }
            guard let pageURL = URL(string: link) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: titleFromSlug(slug),
                    platform: platform ?? .snes,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: link
                )
            )
        }

        return results
    }

    private func titleFromSlug(_ slug: String) -> String {
        slug
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let s = String(part)
                guard let first = s.first else { return s }
                return String(first).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }

    private func platformFromCategories(_ classes: String) -> Platform? {
        let tokens = classes.lowercased().split(separator: " ").map(String.init)
        if tokens.contains("category-playstation-2") { return .ps2 }
        if tokens.contains("category-playstation-portable") { return .psp }
        if tokens.contains("category-playstation") { return .ps1 }
        if tokens.contains("category-nintendo-ds") { return .nds }
        if tokens.contains("category-gameboy-advance") || tokens.contains("category-gba") { return .gba }
        if tokens.contains("category-super-nintendo") || tokens.contains("category-snes") { return .snes }
        if tokens.contains("category-nintendo-64") { return .n64 }
        if tokens.contains("category-gamecube") { return .gameCube }
        if tokens.contains("category-wii") { return .wii }
        if tokens.contains("category-dreamcast") { return .dreamcast }
        if tokens.contains("category-xbox-360") { return .x360 }
        if tokens.contains("category-xbox") { return .xbox }
        return nil
    }
}
