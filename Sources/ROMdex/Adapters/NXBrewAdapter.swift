import Foundation

/// NXBrew — catalogue Nintendo Switch (NSP / XCI) via WordPress REST.
struct NXBrewAdapter: SiteAdapter {
    let id = "nxbrew"
    let displayName = "NXBrew"
    private let baseURL = URL(string: "https://nxbrew.net")!
    /// Catégorie « Switch Games ».
    private let switchCategoryID = 2

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform, platform != .switchPlatform {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://nxbrew.net/wp-json/wp/v2/posts")!
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "categories", value: String(switchCategoryID)),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "_embed", value: "1")
        ]
        guard let url = components.url else { return [] }

        let json = try await HTTPClient.fetchJSON(from: url)
        guard let posts = json as? [[String: Any]] else { return [] }
        return posts.compactMap { parsePost($0) }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard platform == .switchPlatform else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        return try await PaginatedBrowse.collect(through: 20, siteName: displayName) { page in
            var components = URLComponents(string: "https://nxbrew.net/wp-json/wp/v2/posts")!
            components.queryItems = [
                URLQueryItem(name: "categories", value: String(switchCategoryID)),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "_embed", value: "1")
            ]
            guard let url = components.url else { return [] }

            let json = try await HTTPClient.fetchJSON(from: url)
            guard let posts = json as? [[String: Any]] else { return [] }
            return posts.compactMap { parsePost($0) }
        }
    }

    private func parsePost(_ post: [String: Any]) -> GameResult? {
        guard let link = post["link"] as? String,
              let pageURL = URL(string: link) else { return nil }

        let titleRendered: String
        if let titleObj = post["title"] as? [String: Any],
           let rendered = titleObj["rendered"] as? String {
            titleRendered = rendered
        } else if let t = post["title"] as? String {
            titleRendered = t
        } else {
            return nil
        }

        let title = cleanTitle(HTMLParser.decodeEntities(titleRendered))
        guard title.count > 1 else { return nil }

        return GameResult(
            title: title,
            platform: .switchPlatform,
            sourceSite: displayName,
            pageURL: pageURL,
            thumbnailURL: featuredImageURL(from: post),
            genre: genresFromPost(post),
            regionHint: titleRendered
        )
    }

    private func genresFromPost(_ post: [String: Any]) -> String? {
        guard let embedded = post["_embedded"] as? [String: Any],
              let termGroups = embedded["wp:term"] as? [[Any]] else {
            return nil
        }

        var tags: [String] = []
        for group in termGroups {
            for item in group {
                guard let term = item as? [String: Any],
                      (term["taxonomy"] as? String) == "post_tag",
                      let name = term["name"] as? String else { continue }
                tags.append(HTMLParser.decodeEntities(name))
            }
        }
        return GenreParser.fromTags(tags)
    }

    private func featuredImageURL(from post: [String: Any]) -> URL? {
        guard let embedded = post["_embedded"] as? [String: Any],
              let mediaList = embedded["wp:featuredmedia"] as? [[String: Any]],
              let media = mediaList.first else {
            return nil
        }

        let sizes = (media["media_details"] as? [String: Any])?["sizes"] as? [String: Any] ?? [:]

        // Original / full d’abord (portrait ~250×410). Éviter boxstyle/alx (crops 520×292, 200×200…).
        if let src = media["source_url"] as? String, let url = URL(string: src) {
            return CoverArtParser.preferOriginalURL(url)
        }

        let preferredKeys = [
            "full",
            "medium",          // 183×300 portrait
            "boxstyle-list",   // 120×195 portrait
            "large",
            "medium_large"
        ]
        for key in preferredKeys {
            if let size = sizes[key] as? [String: Any],
               let src = size["source_url"] as? String,
               let url = URL(string: src) {
                return CoverArtParser.preferOriginalURL(url)
            }
        }

        // Dernier recours : n’importe quelle taille, puis strip `-WxH` vers l’original.
        for key in ["boxstyle-large", "boxstyle-medium", "boxstyle-small", "alx-medium", "alx-small", "thumbnail"] {
            if let size = sizes[key] as? [String: Any],
               let src = size["source_url"] as? String,
               let url = URL(string: src) {
                return CoverArtParser.preferOriginalURL(url)
            }
        }
        return nil
    }

    private func cleanTitle(_ raw: String) -> String {
        var title = raw
        let suffixes = [
            #"\s*Switch\s+NSP.*$"#,
            #"\s*Switch\s+XCI.*$"#,
            #"\s*\+\s*Update.*$"#,
            #"\s*\+\s*DLCs?.*$"#,
            #"\s*\(eShop\)\s*$"#,
            #"\s*NSP\s*$"#,
            #"\s*XCI\s*$"#
        ]
        for pattern in suffixes {
            title = title.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return title
            .replacingOccurrences(of: #"™|®"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
