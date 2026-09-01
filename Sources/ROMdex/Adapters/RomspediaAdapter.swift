import Foundation

struct RomspediaAdapter: SiteAdapter {
    let id = "romspedia"
    let displayName = "Romspedia"
    private let baseURL = URL(string: "https://www.romspedia.com")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let platforms: [Platform]
        if let platform {
            guard platform.romspediaSlug != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            platforms = [platform]
        } else {
            platforms = [.switchPlatform, .n3ds, .nds, .ps2, .wii]
        }

        let merged = await ParallelFetch.map(platforms) { platform in
            (try? await self.searchOnPlatform(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }

        return await enrichRegions(merged)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard platform.romspediaSlug != nil else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let all = try await PaginatedBrowse.collect(through: 8, siteName: displayName) { page in
            try await fetchBrowsePage(platform: platform, page: page)
        }

        return await enrichRegions(all)
    }

    private func fetchBrowsePage(platform: Platform, page: Int) async throws -> [GameResult] {
        guard let slug = platform.romspediaSlug else { return [] }

        var components = URLComponents(string: "https://www.romspedia.com/roms/\(slug)")!
        if page > 1 {
            components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        }
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        return parse(html: html, platform: platform, slug: slug)
    }

    private func searchOnPlatform(_ query: String, platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.romspediaSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        guard let url = URL(string: "https://www.romspedia.com/roms/\(slug)") else {
            return []
        }

        let html = try await HTTPClient.fetchString(from: url)
        let all = parse(html: html, platform: platform, slug: slug)
        let needle = query.lowercased()

        return all.filter {
            $0.title.lowercased().contains(needle)
                || $0.pageURL.lastPathComponent.lowercased().contains(needle.replacingOccurrences(of: " ", with: "-"))
        }
    }

    private func parse(html: String, platform: Platform, slug: String) -> [GameResult] {
        let thumbs = CoverArtParser.thumbnails(
            in: html,
            pathPattern: #"/roms/\#(slug)/[^"]+"#.replacingOccurrences(of: "#(slug)", with: slug),
            imagePattern: #"https://static\.romspedia\.com/webp/roms/[^"'\s]+"#,
            baseURL: baseURL
        )

        let titlePattern = #"<a href="(/roms/\#(slug)/([^"]+))"[^>]*>\s*<h2[^>]*class="roms-title"[^>]*>([^<]+)</h2>"#
            .replacingOccurrences(of: "#(slug)", with: slug)

        var seen = Set<String>()
        var results: [GameResult] = []

        let titleMatches = HTMLParser.matches(in: html, pattern: titlePattern)
        if !titleMatches.isEmpty {
            for match in titleMatches {
                let path = match.groups[0]
                let slugPart = match.groups[1]
                let title = HTMLParser.decodeEntities(match.groups[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
                guard seen.insert(url.absoluteString).inserted else { continue }

                results.append(
                    GameResult(
                        title: title,
                        platform: platform,
                        sourceSite: displayName,
                        pageURL: url,
                        thumbnailURL: thumbs[path],
                        regionHint: slugPart
                    )
                )
            }
            return results
        }

        let linkPattern = #"<a href="(/roms/\#(slug)/([^"]+))"[^>]*>"#
            .replacingOccurrences(of: "#(slug)", with: slug)

        for match in HTMLParser.matches(in: html, pattern: linkPattern) {
            let path = match.groups[0]
            let slugPart = match.groups[1]
            guard !slugPart.isEmpty else { continue }
            guard let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }

            let title = slugPart
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: url,
                    thumbnailURL: thumbs[path],
                    regionHint: slugPart
                )
            )
        }

        return results
    }

    /// Sur Romspedia, la région est souvent seulement sur la page détail (pas dans le titre listing).
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
        // <div class="view-emulator-detail-name">Region:</div>
        // <div class="view-emulator-detail-value">USA</div>
        if let value = HTMLParser.matches(
            in: html,
            pattern: #"view-emulator-detail-name">\s*Region:\s*</div>\s*<div class="view-emulator-detail-value">\s*([^<]+?)\s*</div>"#
        ).first?.groups.first {
            if let code = GameRegion.fromShortCode(value) {
                return code
            }
            let region = GameRegion.detect(from: value)
            if region != .other { return region }
        }

        // File Name: ... (USA).3ds.7z / ... (F).zip
        if let fileName = HTMLParser.matches(
            in: html,
            pattern: #"view-emulator-detail-name">\s*File Name:\s*</div>\s*<div class="view-emulator-detail-value">\s*([^<]+?)\s*</div>"#
        ).first?.groups.first {
            let region = GameRegion.detect(from: fileName)
            if region != .other { return region }
        }

        return nil
    }
}

extension Platform {
    var romspediaSlug: String? {
        switch self {
        case .gb: return "gameboy"
        case .gbc: return "gameboy-color"
        case .gba: return "gameboy-advance"
        case .nds: return "nintendo-ds"
        case .n3ds: return "nintendo-3ds"
        case .nes: return "nintendo"
        case .snes: return "super-nintendo"
        case .n64: return "nintendo-64"
        case .gameCube: return "nintendo-gamecube"
        case .wii: return "nintendo-wii"
        case .wiiU: return "nintendo-wii-u"
        case .switchPlatform: return "nintendo-switch"
        case .ps1: return "playstation-1"
        case .ps2: return "playstation-2"
        case .ps3: return "playstation-3"
        case .psp: return "playstation-portable"
        case .xbox: return "xbox"
        case .x360: return "xbox-one" // Sur Romspedia, Xbox 360 = /roms/xbox-one
        case .dreamcast: return "sega-dreamcast"
        case .mame: return "mame"
        }
    }
}
