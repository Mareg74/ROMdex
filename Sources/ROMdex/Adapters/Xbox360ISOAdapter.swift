import Foundation

/// Catalogue Xbox 360 via WordPress REST + table wpDataTables.
struct Xbox360ISOAdapter: SiteAdapter {
    let id = "xbox360iso"
    let displayName = "Xbox360ISO"
    private let baseURL = URL(string: "https://xbox360iso.net")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let platform, platform != .x360 {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        var components = URLComponents(string: "https://xbox360iso.net/wp-json/wp/v2/posts")!
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "_embed", value: "1")
        ]
        guard let url = components.url else { return [] }

        let json = try await HTTPClient.fetchJSON(from: url)
        guard let posts = json as? [[String: Any]] else { return [] }
        return posts.compactMap { parsePost($0) }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard platform == .x360 else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let all: [GameResult]
        do {
            all = try await PaginatedBrowse.collect(through: 20, siteName: displayName) { page in
                var components = URLComponents(string: "https://xbox360iso.net/wp-json/wp/v2/posts")!
                components.queryItems = [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "_embed", value: "1")
                ]
                guard let url = components.url else { return [] }

                let json = try await HTTPClient.fetchJSON(from: url)
                guard let posts = json as? [[String: Any]] else { return [] }
                return posts.compactMap { parsePost($0) }
            }
        } catch {
            return try await browseViaDataTable()
        }

        if all.isEmpty {
            return try await browseViaDataTable()
        }

        return await enrichMissingCovers(all)
    }

    private func browseViaDataTable() async throws -> [GameResult] {
        let homeHTML = try await HTTPClient.fetchString(from: baseURL)
        let nonce = HTMLParser.matches(
            in: homeHTML,
            pattern: #"name="wdtNonceFrontendEdit_1"\s+value="([^"]+)""#
        ).first?.groups.first ?? ""

        var all: [GameResult] = []
        var seen = Set<String>()
        let pageSize = 200
        var start = 0

        while start < 2500 {
            let ajaxURL = URL(string: "https://xbox360iso.net/wp-admin/admin-ajax.php?action=get_wdtable&table_id=1")!
            let data = try await HTTPClient.postForm(url: ajaxURL, fields: [
                "draw": "1",
                "start": String(start),
                "length": String(pageSize),
                "wdtNonce": nonce
            ])

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["data"] as? [[Any]] else {
                break
            }
            if rows.isEmpty { break }

            for row in rows {
                guard row.count >= 2,
                      let titleRaw = row[1] as? String else { continue }
                let cleaned = cleanTitle(titleRaw)
                guard cleaned.count > 1 else { continue }

                let region = GameRegion.detect(from: titleRaw)
                var components = URLComponents(string: "https://xbox360iso.net/")!
                components.queryItems = [URLQueryItem(name: "s", value: cleaned)]
                guard let pageURL = components.url else { continue }
                guard seen.insert(cleaned.lowercased()).inserted else { continue }

                all.append(
                    GameResult(
                        title: cleaned,
                        platform: .x360,
                        region: region,
                        sourceSite: displayName,
                        pageURL: pageURL,
                        regionHint: titleRaw
                    )
                )
            }

            start += pageSize
            if let total = Int(json["recordsTotal"] as? String ?? ""), start >= total {
                break
            }
            if rows.count < pageSize { break }
        }

        CatalogBrowseProgress.reportGames(site: displayName, all)
        return await enrichMissingCovers(all)
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

        let thumb = featuredImageURL(from: post)

        return GameResult(
            title: title,
            platform: .x360,
            sourceSite: displayName,
            pageURL: pageURL,
            thumbnailURL: thumb,
            regionHint: titleRendered
        )
    }

    /// Extrait la jaquette depuis `_embedded.wp:featuredmedia` (API WP avec `_embed=1`).
    private func featuredImageURL(from post: [String: Any]) -> URL? {
        guard let embedded = post["_embedded"] as? [String: Any],
              let mediaList = embedded["wp:featuredmedia"] as? [[String: Any]],
              let media = mediaList.first else {
            return nil
        }

        let sizes = (media["media_details"] as? [String: Any])?["sizes"] as? [String: Any] ?? [:]
        let preferredKeys = [
            "gamezone-thumb-med",
            "medium_large",
            "medium",
            "trx_addons-thumb-small",
            "thumbnail",
            "full"
        ]

        for key in preferredKeys {
            if let size = sizes[key] as? [String: Any],
               let src = size["source_url"] as? String,
               let url = URL(string: src),
               isLikelyCover(url) {
                return url
            }
        }

        if let src = media["source_url"] as? String,
           let url = URL(string: src),
           isLikelyCover(url) {
            return url
        }

        return nil
    }

    private func isLikelyCover(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        if s.contains("logo") || s.contains("spinner") || s.contains("avatar") { return false }
        return true
    }

    /// Pour les entrées sans featured media : og:image / img « cover » sur la fiche.
    private func enrichMissingCovers(_ results: [GameResult]) async -> [GameResult] {
        let missing = results.filter { $0.thumbnailURL == nil }
        guard !missing.isEmpty else { return results }

        let covers = await withTaskGroup(of: (URL, URL?).self) { group in
            for result in missing.prefix(60) {
                group.addTask {
                    (result.pageURL, await self.fetchCover(from: result.pageURL))
                }
            }
            var map: [URL: URL] = [:]
            for await (page, cover) in group {
                if let cover { map[page] = cover }
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
        // Les URLs `?s=` du fallback table ne sont pas de vraies fiches.
        guard url.path.count > 1, url.query == nil else { return nil }
        guard let html = try? await HTTPClient.fetchString(from: url) else { return nil }

        // Préférer une vraie jaquette « front-cover ».
        let coverPattern = #"(https://xbox360iso\.net/wp-content/uploads/[^"'\s]*front-cover[^"'\s]*\.(?:jpg|jpeg|png|webp))"#
        if let match = HTMLParser.matches(in: html, pattern: coverPattern).first,
           let cover = URL(string: match.groups[0]) {
            return cover
        }

        let ogPattern = #"(?:property|name)="og:image"[^>]*content="(https://xbox360iso\.net/[^"]+)""#
        if let match = HTMLParser.matches(in: html, pattern: ogPattern).first,
           let cover = URL(string: match.groups[0]),
           isLikelyCover(cover) {
            return cover
        }

        let ogAlt = #"content="(https://xbox360iso\.net/wp-content/uploads/[^"]+)"[^>]*(?:property|name)="og:image""#
        if let match = HTMLParser.matches(in: html, pattern: ogAlt).first,
           let cover = URL(string: match.groups[0]),
           isLikelyCover(cover) {
            return cover
        }

        return nil
    }

    private func cleanTitle(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"XBOX360ISO\.?net?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "XBOX360ISO", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
