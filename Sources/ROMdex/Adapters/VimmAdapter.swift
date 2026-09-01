import Foundation

struct VimmAdapter: SiteAdapter {
    let id = "vimm"
    let displayName = "Vimm's Lair"
    private let baseURL = URL(string: "https://vimm.net")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let platformsToSearch: [Platform]
        if let platform {
            guard platform.vimmSystemID != nil else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            platformsToSearch = [platform]
        } else {
            platformsToSearch = Platform.allCases.filter { $0.vimmSystemID != nil }
        }

        return await ParallelFetch.map(platformsToSearch) { platform -> [GameResult] in
            guard let systemID = platform.vimmSystemID else { return [] }
            var components = URLComponents(string: "https://vimm.net/vault/")!
            components.queryItems = [
                URLQueryItem(name: "p", value: "list"),
                URLQueryItem(name: "system", value: systemID),
                URLQueryItem(name: "q", value: trimmed)
            ]
            guard let url = components.url else { return [] }
            let html = (try? await HTTPClient.fetchString(from: url)) ?? ""
            return self.parse(html: html, platform: platform)
        }.flatMap { $0 }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let systemID = platform.vimmSystemID else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let sections = ["0"] + (65 ... 90).map { String(UnicodeScalar($0)!) }

        let batches = await ParallelFetch.mapOptional(sections) { section -> [GameResult]? in
            var components = URLComponents(string: "https://vimm.net/vault/")!
            components.queryItems = [
                URLQueryItem(name: "p", value: "list"),
                URLQueryItem(name: "system", value: systemID),
                URLQueryItem(name: "section", value: section)
            ]
            guard let url = components.url else { return nil }
            let html = (try? await HTTPClient.fetchString(from: url)) ?? ""
            return self.parse(html: html, platform: platform)
        }

        return PaginatedBrowse.merge(siteName: displayName, batches: batches)
    }

    private func parse(html: String, platform: Platform) -> [GameResult] {
        // Capture le lien du jeu + le contenu de la cellule région (drapeaux).
        let rowPattern = #"<tr>.*?<a href=\s*"/vault/(\d+)"[^>]*>([^<]+)</a>.*?<td[^>]*>((?:(?!</td>).)*)</td>"#
        let matches = HTMLParser.matches(in: html, pattern: rowPattern)

        var seen = Set<String>()
        var results: [GameResult] = []

        if !matches.isEmpty {
            for match in matches {
                if let result = makeResult(
                    gameID: match.groups[0],
                    titleHTML: match.groups[1],
                    regionHTML: match.groups[2],
                    platform: platform,
                    seen: &seen
                ) {
                    results.append(result)
                }
            }
            return results
        }

        // Fallback si le parsing de ligne échoue.
        let linkPattern = #"<a href=\s*"/vault/(\d+)"[^>]*>([^<]+)</a>"#
        for match in HTMLParser.matches(in: html, pattern: linkPattern) {
            if let result = makeResult(
                gameID: match.groups[0],
                titleHTML: match.groups[1],
                regionHTML: nil,
                platform: platform,
                seen: &seen
            ) {
                results.append(result)
            }
        }

        return results
    }

    private func makeResult(
        gameID: String,
        titleHTML: String,
        regionHTML: String?,
        platform: Platform,
        seen: inout Set<String>
    ) -> GameResult? {
        if gameID == "999999" { return nil }

        let title = HTMLParser.decodeEntities(titleHTML)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard title.count > 1 else { return nil }
        guard let url = URL(string: "https://vimm.net/vault/\(gameID)") else { return nil }

        let key = "\(gameID)|\(title.lowercased())"
        guard seen.insert(key).inserted else { return nil }

        let regionHint = regionHint(from: regionHTML)
        return GameResult(
            title: title,
            platform: platform,
            sourceSite: displayName,
            pageURL: url,
            regionHint: regionHint
        )
    }

    private func regionHint(from regionHTML: String?) -> String? {
        guard let regionHTML else { return nil }

        let flagTitles = HTMLParser.matches(in: regionHTML, pattern: #"title="([^"]+)""#)
            .compactMap { $0.groups.first }
        if !flagTitles.isEmpty {
            return flagTitles.joined(separator: " ")
        }

        let flagFiles = HTMLParser.matches(in: regionHTML, pattern: #"flags/([a-z0-9_-]+)\.(?:png|svg|gif)"#)
            .compactMap { $0.groups.first }
        if !flagFiles.isEmpty {
            return flagFiles.joined(separator: " ")
        }

        return nil
    }
}
