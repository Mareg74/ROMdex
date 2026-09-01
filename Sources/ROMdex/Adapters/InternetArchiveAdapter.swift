import Foundation

/// Internet Archive — Xbox / Xbox 360 / PS3 (évite les faux positifs « Also For »).
struct InternetArchiveAdapter: SiteAdapter {
    let id = "internetarchive"
    let displayName = "Internet Archive"
    private let baseURL = URL(string: "https://archive.org")!

    private static let supported: Set<Platform> = [.xbox, .x360, .ps3]

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let platforms: [Platform]
        if let platform {
            guard Self.supported.contains(platform) else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            platforms = [platform]
        } else {
            platforms = Array(Self.supported)
        }

        return await ParallelFetch.map(platforms) { platform in
            (try? await self.searchOnPlatform(trimmed, platform: platform)) ?? []
        }.flatMap { $0 }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard Self.supported.contains(platform) else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        // Collections dédiées plutôt qu’une recherche libre (trop de faux positifs).
        return try await searchOnPlatform("*", platform: platform, rows: 200, browseMode: true)
    }

    private func searchOnPlatform(
        _ query: String,
        platform: Platform,
        rows: Int = 40,
        browseMode: Bool = false
    ) async throws -> [GameResult] {
        let q: String
        switch platform {
        case .x360:
            // Exige collection xbox360* OU Xbox 360 dans le titre — pas un simple « Also For ».
            let titlePart = browseMode ? "" : "title:(\(sanitizeQuery(query))) AND "
            q = """
            \(titlePart)mediatype:software AND year:[2005 TO 2026] \
            AND (collection:xbox360* OR title:("Xbox 360" OR Xbox360 OR "[X360]" OR "(Xbox 360)" OR "XBOX 360"))
            """
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        case .xbox:
            let titlePart = browseMode ? "" : "title:(\(sanitizeQuery(query))) AND "
            q = """
            \(titlePart)mediatype:software AND year:[2001 TO 2013] \
            AND (collection:(xbox*) OR title:("[Xbox]" OR "(Xbox)" OR "OG Xbox" OR "Original Xbox")) \
            AND NOT (collection:xbox360* OR title:("Xbox 360" OR Xbox360))
            """
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        case .ps3:
            let titlePart = browseMode ? "" : "title:(\(sanitizeQuery(query))) AND "
            q = """
            \(titlePart)mediatype:software AND year:[2006 TO 2026] \
            AND (collection:(ps3* OR playstation3*) OR title:("PlayStation 3" OR Playstation3 OR PS3 OR "[PS3]" OR "(PS3)"))
            """
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        default:
            return []
        }

        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "year"),
            URLQueryItem(name: "fl[]", value: "collection"),
            URLQueryItem(name: "fl[]", value: "subject"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json")
        ]
        guard let url = components.url else { return [] }

        let json = try await HTTPClient.fetchJSON(from: url)
        guard let root = json as? [String: Any],
              let response = root["response"] as? [String: Any],
              let docs = response["docs"] as? [[String: Any]] else {
            return []
        }

        let results = docs.compactMap { doc in
            parseDoc(doc, platform: platform)
        }
        CatalogBrowseProgress.reportGames(site: displayName, results)
        return results
    }

    private func parseDoc(_ doc: [String: Any], platform: Platform) -> GameResult? {
        guard let identifier = doc["identifier"] as? String,
              let title = doc["title"] as? String else { return nil }

        let cleaned = HTMLParser.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 1 else { return nil }

        let year: Int?
        if let y = doc["year"] as? String {
            year = Int(y)
        } else if let y = doc["year"] as? Int {
            year = y
        } else {
            year = ReleaseYearParser.detect(from: cleaned)
        }

        let collections = collectionNames(from: doc)
        guard isPrimaryPlatformMatch(
            title: cleaned,
            year: year,
            collections: collections,
            platform: platform
        ) else {
            return nil
        }

        guard let pageURL = URL(string: "https://archive.org/details/\(identifier)") else { return nil }
        let thumb = URL(string: "https://archive.org/services/img/\(identifier)")
        let genre = GenreParser.fromSubjects(subjectNames(from: doc))

        return GameResult(
            title: cleaned,
            platform: platform,
            sourceSite: displayName,
            pageURL: pageURL,
            thumbnailURL: thumb,
            releaseYear: year,
            genre: genre,
            regionHint: cleaned
        )
    }

    private func subjectNames(from doc: [String: Any]) -> [String] {
        if let array = doc["subject"] as? [String] {
            return array
        }
        if let single = doc["subject"] as? String {
            return [single]
        }
        return []
    }

    /// Rejette les titres où Xbox 360 n’apparaît que dans « Also For » (Amiga, Arcade, NES…).
    private func isPrimaryPlatformMatch(
        title: String,
        year: Int?,
        collections: [String],
        platform: Platform
    ) -> Bool {
        let t = title.lowercased()
        let coll = collections.joined(separator: " ").lowercased()

        switch platform {
        case .x360:
            if let year, year < 2005 { return false }

            let dedicatedCollection = coll.contains("xbox360")
                || coll.contains("xbox_360")
                || coll.contains("x360")

            let titledFor360 = t.contains("xbox 360")
                || t.contains("xbox360")
                || t.contains("[x360]")
                || t.contains("(x360)")
                || t.contains("[xbox 360]")
                || t.contains("(xbox 360)")

            // Collection dédiée = OK. Sinon le titre doit clairement viser la 360.
            guard dedicatedCollection || titledFor360 else { return false }

            // Écarter les dumps 8/16-bit / home computer même si « Also For » cite la 360.
            let classicMarkers = [
                "amiga", "amstrad", "zx spectrum", "atari st", "commodore",
                "nes)", "(nes", "[nes]", "famicom", "arcade", "mame", "cps1", "cps2"
            ]
            if !dedicatedCollection,
               classicMarkers.contains(where: { t.contains($0) }),
               !titledFor360 {
                return false
            }

            return true

        case .xbox:
            if let year, year < 2001 || year > 2013 { return false }

            let dedicatedCollection = (coll.contains("xbox") && !coll.contains("xbox360") && !coll.contains("xbox_360"))
            let titledForXbox = (t.contains("[xbox]") || t.contains("(xbox)") || t.contains("og xbox") || t.contains("original xbox"))
                && !t.contains("360")

            return dedicatedCollection || titledForXbox

        case .ps3:
            if let year, year < 2006 { return false }

            let dedicatedCollection = coll.contains("ps3")
                || coll.contains("playstation3")
                || coll.contains("playstation_3")
                || coll.contains("sony_playstation_3")

            let titledForPS3 = t.contains("playstation 3")
                || t.contains("playstation3")
                || t.contains("[ps3]")
                || t.contains("(ps3)")
                || t.contains(" ps3 ")
                || t.hasSuffix(" ps3")
                || t.hasPrefix("ps3 ")

            return dedicatedCollection || titledForPS3

        default:
            return false
        }
    }

    private func collectionNames(from doc: [String: Any]) -> [String] {
        if let array = doc["collection"] as? [String] {
            return array
        }
        if let single = doc["collection"] as? String {
            return [single]
        }
        return []
    }

    private func sanitizeQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"[+\-&|!(){}\[\]^"~*?:\\]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
