import Foundation

struct RetrosticAdapter: SiteAdapter {
    let id = "retrostic"
    let displayName = "Retrostic"
    private let baseURL = URL(string: "https://www.retrostic.com")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let initial: [GameResult]
        if let platform {
            initial = try await searchOnPlatform(trimmed, platform: platform)
        } else {
            var components = URLComponents(string: "https://www.retrostic.com/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "search_term_string", value: trimmed)
            ]
            guard let url = components.url else { return [] }
            let html = try await HTTPClient.fetchString(from: url)
            initial = parseGlobal(html: html)
        }

        return await enrichRegions(initial)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.retrosticSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let all = try await PaginatedBrowse.collect(through: 10, siteName: displayName) { page in
            var components = URLComponents(string: "https://www.retrostic.com/roms/\(slug)")!
            if page > 1 {
                components.queryItems = [URLQueryItem(name: "page", value: String(page))]
            }
            guard let url = components.url else { return [] }

            let html = try await HTTPClient.fetchString(from: url)
            return parse(html: html, platform: platform, slug: slug)
        }

        return await enrichRegions(all)
    }

    private func searchOnPlatform(_ query: String, platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.retrosticSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://www.retrostic.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "search_term_string", value: query)
        ]

        guard let url = components.url else { return [] }
        let html = try await HTTPClient.fetchString(from: url)
        return parse(html: html, platform: platform, slug: slug)
    }

    private func parseGlobal(html: String) -> [GameResult] {
        let thumbs = CoverArtParser.thumbnails(
            in: html,
            pathPattern: #"/roms/[a-z0-9-]+/[^"]+"#,
            imagePattern: #"/img/screenshots/[^"'\s]+|https?://[^"'\s]*screenshots[^"'\s]*"#,
            baseURL: baseURL
        )

        let pattern = #"<a href="(/roms/([a-z0-9-]+)/[^"]+)"[^>]*>(?:<img[^>]*>)?\s*(?:<span itemprop="name">)?\s*([^<]+?)\s*(?:</span>)?\s*</a>"#
        var seen = Set<String>()

        return HTMLParser.matches(in: html, pattern: pattern).compactMap { match in
            let path = match.groups[0]
            let slug = match.groups[1]
            let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }

            let platform = Platform.allCases.first { $0.retrosticSlug == slug } ?? .snes
            let hint = regionHintFromListing(html: html, path: path) ?? path
            return GameResult(
                title: title,
                platform: platform,
                sourceSite: displayName,
                pageURL: url,
                thumbnailURL: thumbs[path],
                regionHint: hint
            )
        }
    }

    private func parse(html: String, platform: Platform, slug: String) -> [GameResult] {
        let thumbs = CoverArtParser.thumbnails(
            in: html,
            pathPattern: #"/roms/\#(slug)/[^"]+"#.replacingOccurrences(of: "#(slug)", with: slug),
            imagePattern: #"/img/screenshots/[^"'\s]+|https?://[^"'\s]*screenshots[^"'\s]*"#,
            baseURL: baseURL
        )

        let pattern = #"<a href="(/roms/\#(slug)/[^"]+)"[^>]*(?:title="([^"]*)")?[^>]*>(?:<img[^>]*>)?\s*(?:<span itemprop="name">)?\s*([^<]+?)\s*(?:</span>)?\s*</a>"#
            .replacingOccurrences(of: "#(slug)", with: slug)

        let matches = HTMLParser.matches(in: html, pattern: pattern)
        var seen = Set<String>()
        var results: [GameResult] = []

        for match in matches {
            let path = match.groups[0]
            let titleFromAttr = match.groups.count > 1 ? match.groups[1] : ""
            let titleFromText = match.groups.count > 2 ? match.groups[2] : ""

            var title = titleFromText.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                title = titleFromAttr
                    .replacingOccurrences(of: " Rom", with: "")
                    .replacingOccurrences(of: " Roms", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            title = HTMLParser.decodeEntities(title)
            guard !title.isEmpty else { continue }
            guard let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }

            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }

            let hint = regionHintFromListing(html: html, path: path) ?? path
            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: url,
                    thumbnailURL: thumbs[path],
                    regionHint: hint
                )
            )
        }

        if results.isEmpty {
            return parseFallback(html: html, platform: platform, slug: slug, thumbs: thumbs)
        }

        return results
    }

    private func parseFallback(
        html: String,
        platform: Platform,
        slug: String,
        thumbs: [String: URL]
    ) -> [GameResult] {
        let pattern = #"<a href="(/roms/\#(slug)/[^"]+)"[^>]*>([^<]+)</a>"#
            .replacingOccurrences(of: "#(slug)", with: slug)

        var seen = Set<String>()
        return HTMLParser.matches(in: html, pattern: pattern).compactMap { match in
            let path = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            let hint = regionHintFromListing(html: html, path: path) ?? path
            return GameResult(
                title: title,
                platform: platform,
                sourceSite: displayName,
                pageURL: url,
                thumbnailURL: thumbs[path],
                regionHint: hint
            )
        }
    }

    /// Cherche un drapeau voisin du lien dans le HTML de listing.
    private func regionHintFromListing(html: String, path: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: path)
        let forward = escaped + #"[\s\S]{0,1200}?flags/([a-z]{2})\.(?:svg|png)"#
        if let flag = HTMLParser.matches(in: html, pattern: forward).first?.groups.first {
            return flag
        }

        let reverse = #"flags/([a-z]{2})\.(?:svg|png)[\s\S]{0,800}?"# + escaped
        return HTMLParser.matches(in: html, pattern: reverse).first?.groups.first
    }

    /// Priorise la région de la page détail (drapeau / Region / File Name).
    /// Corrige aussi les faux positifs du type `[T-German]` → EU alors que le dump est US.
    private func enrichRegions(_ results: [GameResult]) async -> [GameResult] {
        let needsEnrichment = results.filter {
            $0.region == .other || GameRegion.titleLooksTranslated($0.title)
        }
        guard !needsEnrichment.isEmpty else { return results }

        let enriched = await withTaskGroup(of: (URL, GameRegion?).self) { group in
            for result in needsEnrichment.prefix(25) {
                group.addTask {
                    (result.pageURL, await self.fetchRegion(from: result.pageURL))
                }
            }

            var map: [URL: GameRegion] = [:]
            for await (url, region) in group {
                if let region, region != .other {
                    map[url] = region
                }
            }
            return map
        }

        guard !enriched.isEmpty else { return results }

        return results.map { result in
            guard let region = enriched[result.pageURL] else { return result }
            return result.updatingRegion(region, forPageURL: result.pageURL)
        }
    }

    private func fetchRegion(from url: URL) async -> GameRegion? {
        guard let html = try? await HTTPClient.fetchString(from: url) else { return nil }
        return parseRegion(fromDetailHTML: html)
    }

    private func parseRegion(fromDetailHTML html: String) -> GameRegion? {
        // <span itemprop="gameLocation">FR</span>
        if let location = HTMLParser.matches(
            in: html,
            pattern: #"itemprop="gameLocation">\s*([^<]+?)\s*</span>"#
        ).first?.groups.first {
            if let code = GameRegion.fromShortCode(location) {
                return code
            }
            let region = GameRegion.detect(from: location)
            if region != .other { return region }
        }

        // Ligne Region: + drapeau (ex. flags/fr.svg + (FR))
        if let cell = HTMLParser.matches(
            in: html,
            pattern: #"Region:</td>\s*<td>([\s\S]*?)</td>"#
        ).first?.groups.first {
            if let codeMatch = HTMLParser.matches(in: cell, pattern: #"\(([A-Z]{1,3})\)"#).first?.groups.first,
               let code = GameRegion.fromShortCode(codeMatch) {
                return code
            }
            let region = GameRegion.detect(from: cell)
            if region != .other { return region }
        }

        // Nom de fichier : Legend of Zelda, The (F).zip
        if let fileName = HTMLParser.matches(
            in: html,
            pattern: #"File Name:</td>\s*<td>([^<]+)</td>"#
        ).first?.groups.first {
            let region = GameRegion.detect(from: fileName)
            if region != .other { return region }
        }

        return nil
    }
}
