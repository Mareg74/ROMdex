import Foundation

struct RomHustlerAdapter: SiteAdapter {
    let id = "romhustler"
    let displayName = "RomHustler"
    private let baseURL = URL(string: "https://romhustler.org")!
    /// Pages max par listing (GBC ~39, GBA ~48).
    private let maxBrowsePages = 50

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://romhustler.org/roms/search")!
        components.queryItems = [URLQueryItem(name: "query", value: trimmed)]
        guard let url = components.url else { return [] }

        let html = try await HTTPClient.fetchString(from: url)
        let all = parse(html: html, forcedPlatform: nil)

        let filtered: [GameResult]
        if let platform {
            guard platform.romHustlerListingSlug != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            // GB et GBC partagent le listing « Gameboy / Color ».
            if platform == .gb || platform == .gbc {
                filtered = all.filter { $0.platform == .gb || $0.platform == .gbc }
            } else {
                filtered = all.filter { $0.platform == platform }
            }
        } else {
            filtered = all
        }

        return await enrichCovers(filtered)
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let slug = platform.romHustlerListingSlug else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let all = try await PaginatedBrowse.collect(through: maxBrowsePages, siteName: displayName) { page in
            let url: URL
            if page == 1 {
                guard let u = URL(string: "https://romhustler.org/roms/\(slug)") else { return [] }
                url = u
            } else {
                guard let u = URL(string: "https://romhustler.org/roms/\(slug)/\(page)") else { return [] }
                url = u
            }

            let html = try await HTTPClient.fetchString(from: url)
            return parse(html: html, forcedPlatform: platform)
        }

        // Jaquettes : l’enrichissement massif se fait via le catalogue (évite 2000+ fetches ici).
        return all
    }

    private func parse(html: String, forcedPlatform: Platform?) -> [GameResult] {
        // Ligne : drapeau + lien jeu (listing RomHustler / RomUlation-like).
        let rowPattern = #"<tr>[\s\S]*?<span class="(flags-[a-z]+)">[^<]*</span>[\s\S]*?<a href="(?:https://romhustler\.org)?(/rom/([a-z0-9-]+)/[^"]+)"[^>]*>\s*(?:\[[^\]]+\]\s*)?([^<]+)</a>"#
        var seen = Set<String>()
        var results: [GameResult] = []

        let matches = HTMLParser.matches(in: html, pattern: rowPattern)
        if !matches.isEmpty {
            for match in matches {
                let flagClass = match.groups[0]
                let path = match.groups[1]
                let slug = match.groups[2]
                let rawTitle = match.groups[3]
                let title = cleanTitle(rawTitle)
                guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
                guard seen.insert(url.absoluteString).inserted else { continue }

                let platform = forcedPlatform
                    ?? platformFromSlug(slug)
                    ?? platformFromTitleMarkers(rawTitle)
                    ?? platformFromBracket(rawTitle)
                    ?? .snes

                results.append(
                    GameResult(
                        title: title,
                        platform: platform,
                        sourceSite: displayName,
                        pageURL: url,
                        regionHint: flagClass
                    )
                )
            }
            return results
        }

        // Fallback sans drapeau.
        let linkPattern = #"<a href="(?:https://romhustler\.org)?(/rom/([a-z0-9-]+)/[^"]+)"[^>]*>\s*(?:\[[^\]]+\]\s*)?([^<]+)</a>"#
        for match in HTMLParser.matches(in: html, pattern: linkPattern) {
            let path = match.groups[0]
            let slug = match.groups[1]
            let rawTitle = match.groups[2]
            let title = cleanTitle(rawTitle)
            guard !title.isEmpty, let url = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: forcedPlatform
                        ?? platformFromSlug(slug)
                        ?? platformFromTitleMarkers(rawTitle)
                        ?? .snes,
                    sourceSite: displayName,
                    pageURL: url,
                    regionHint: path
                )
            )
        }

        return results
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = HTMLParser.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = title.range(of: #"^\[[^\]]+\]\s*"#, options: .regularExpression) {
            title.removeSubrange(bracket)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mapping explicite des slugs d’URL `/rom/{slug}/…` (évite l’ambiguïté GB/GBC).
    private func platformFromSlug(_ slug: String) -> Platform? {
        switch slug {
        case "gb": return .gb
        case "gbc": return .gbc
        case "gba": return .gba
        case "nds": return .nds
        case "nintendo-3ds": return .n3ds
        case "nes": return .nes
        case "snes": return .snes
        case "n64": return .n64
        case "gamecube": return .gameCube
        case "wii": return .wii
        case "psx": return .ps1
        case "playstation2", "ps2": return .ps2
        case "playstation-portable", "psp": return .psp
        case "dreamcast": return .dreamcast
        case "mame": return .mame
        default: return nil
        }
    }

    /// Sur le listing commun GB/GBC, `[C]` indique souvent une ROM Color.
    private func platformFromTitleMarkers(_ raw: String) -> Platform? {
        let t = raw.uppercased()
        if t.contains("[C]") || t.contains("(C)") { return .gbc }
        return nil
    }

    private func platformFromBracket(_ raw: String) -> Platform? {
        guard let match = HTMLParser.matches(in: raw, pattern: #"^\[([^\]]+)\]"#).first else { return nil }
        let label = match.groups[0].lowercased()
            .replacingOccurrences(of: #"[\s/_-]+"#, with: "", options: .regularExpression)

        if label.contains("gameboyadvance") || label == "gba" { return .gba }
        if label.contains("gameboycolor") || label.contains("gameboycolour")
            || label == "gbc" || label.contains("gameboy/color") { return .gbc }
        if label.contains("gameboy") || label == "gb" || label == "dmg" { return .gb }
        if label.contains("nintendods") || label == "nds" { return .nds }
        if label.contains("3ds") { return .n3ds }
        if label.contains("supernintendo") || label == "snes" { return .snes }
        if label.contains("nintendo64") || label == "n64" { return .n64 }
        if label == "nes" || label.contains("famicom") { return .nes }
        if label.contains("gamecube") { return .gameCube }
        if label.contains("wii") { return .wii }
        if label.contains("playstation2") || label == "ps2" { return .ps2 }
        if label.contains("playstationportable") || label == "psp" { return .psp }
        if label.contains("playstation") || label == "psx" || label == "ps1" { return .ps1 }
        if label.contains("dreamcast") { return .dreamcast }
        if label.contains("mame") { return .mame }
        return nil
    }

    /// Les listes n’ont pas de jaquette — on prend le screenshot titre de la page détail.
    private func enrichCovers(_ results: [GameResult]) async -> [GameResult] {
        let missing = results.filter { $0.thumbnailURL == nil }
        guard !missing.isEmpty else { return results }

        let covers = await withTaskGroup(of: (URL, URL?).self) { group in
            var iterator = missing.prefix(120).makeIterator()
            let concurrency = min(8, missing.count)

            for _ in 0 ..< concurrency {
                guard let result = iterator.next() else { break }
                group.addTask {
                    CatalogBrowseProgress.reportEnriching(title: result.title, url: result.pageURL)
                    return (result.pageURL, await self.fetchCover(from: result.pageURL))
                }
            }

            var map: [URL: URL] = [:]
            while let (page, cover) = await group.next() {
                if let cover { map[page] = cover }
                if let result = iterator.next() {
                    group.addTask {
                        CatalogBrowseProgress.reportEnriching(title: result.title, url: result.pageURL)
                        return (result.pageURL, await self.fetchCover(from: result.pageURL))
                    }
                }
            }
            return map
        }

        guard !covers.isEmpty else { return results }

        return results.map { result in
            guard let thumb = covers[result.pageURL] else { return result }
            return result.updatingThumbnail(thumb, forPageURL: result.pageURL)
        }
    }

    private func fetchCover(from url: URL) async -> URL? {
        guard let html = try? await HTTPClient.fetchString(from: url) else { return nil }
        return CoverArtParser.romHustlerCover(fromHTML: html)
    }
}

extension Platform {
    /// Slug du listing catalogue RomHustler (`/roms/{slug}` et `/roms/{slug}/2`…).
    /// GB et GBC partagent [Gameboy / Color](https://romhustler.org/roms/gbc).
    var romHustlerListingSlug: String? {
        switch self {
        case .gb, .gbc: return "gbc"
        case .gba: return "gba"
        case .nds: return "nds"
        case .n3ds: return "nintendo-3ds"
        case .nes: return "nes"
        case .snes: return "snes"
        case .n64: return "n64"
        case .gameCube: return "gamecube"
        case .wii: return "wii"
        case .wiiU: return nil
        case .switchPlatform: return nil
        case .ps1: return "psx"
        case .ps2: return "playstation2"
        case .ps3: return "ps3"
        case .psp: return "playstation-portable"
        case .xbox: return nil
        case .x360: return nil
        case .dreamcast: return "dreamcast"
        case .mame: return "mame"
        }
    }

    /// Ancien nom (recherche / compat).
    var romHustlerSlug: String? { romHustlerListingSlug }
}
