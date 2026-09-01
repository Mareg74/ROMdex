import Foundation

/// Enrichissement stateless pour les rebuilds catalogue (parallélisable).
enum CatalogRebuildEnricher {
    struct ThumbnailPatch: Sendable {
        let game: GameResult
        let sourceName: String
    }

    struct DatePatch: Sendable {
        let game: GameResult
        let filled: Bool
        let clearedSuspect: Bool
        let sourceName: String?
    }

    /// Cascade TheGamesDB → LaunchBox → Libretro (HTTP / API uniquement).
    static func fetchThumbnail(for game: GameResult, platform: Platform) async -> ThumbnailPatch? {
        guard !CoverArtParser.isUsableCover(game.thumbnailURL) else { return nil }

        if let patched = await theGamesDBCover(for: game) {
            return ThumbnailPatch(game: patched, sourceName: "TheGamesDB")
        }
        if let patched = await launchBoxCover(for: game) {
            return ThumbnailPatch(game: patched, sourceName: "LaunchBox")
        }
        if platform.libretroSystemFolder != nil,
           let cover = await LibretroThumbnails.shared.coverURL(
               title: game.title,
               platform: platform,
               region: game.region
           ) {
            let page = CatalogMetaRouting.pageURL(for: game)
            return ThumbnailPatch(
                game: game.updatingThumbnail(cover, forPageURL: page),
                sourceName: "Libretro"
            )
        }
        return nil
    }

    /// Dates via API / HTTP (pas RomsFun WebKit).
    static func fetchReleaseYearHTTP(for game: GameResult) async -> DatePatch {
        let isSuspectCorrection = game.releaseYear != nil
            && CatalogMetaRouting.needsReleaseYearRefresh(game)
        let working = isSuspectCorrection ? game.withReleaseYear(nil) : game

        if let year = await theGamesDBYear(for: working, allowCorrection: isSuspectCorrection) {
            return DatePatch(
                game: working.withReleaseYear(year),
                filled: true,
                clearedSuspect: false,
                sourceName: "TheGamesDB"
            )
        }

        if let year = await launchBoxYear(for: working, allowCorrection: isSuspectCorrection) {
            return DatePatch(
                game: working.withReleaseYear(year),
                filled: true,
                clearedSuspect: false,
                sourceName: "LaunchBox"
            )
        }

        if let year = await httpReleaseYear(for: working) {
            return DatePatch(
                game: working.withReleaseYear(year),
                filled: true,
                clearedSuspect: false,
                sourceName: working.sourceSite
            )
        }

        return DatePatch(
            game: working,
            filled: false,
            clearedSuspect: isSuspectCorrection,
            sourceName: nil
        )
    }

    /// Dates RomsFun via WebKit (séquentiel côté appelant).
    static func fetchReleaseYearBrowser(for game: GameResult) async -> DatePatch {
        let isSuspectCorrection = game.releaseYear != nil
            && CatalogMetaRouting.needsReleaseYearRefresh(game)
        let working = isSuspectCorrection ? game.withReleaseYear(nil) : game

        if let year = await theGamesDBYear(for: working, allowCorrection: isSuspectCorrection) {
            return DatePatch(
                game: working.withReleaseYear(year),
                filled: true,
                clearedSuspect: false,
                sourceName: "TheGamesDB"
            )
        }

        if let year = await launchBoxYear(for: working, allowCorrection: isSuspectCorrection) {
            return DatePatch(
                game: working.withReleaseYear(year),
                filled: true,
                clearedSuspect: false,
                sourceName: "LaunchBox"
            )
        }

        let page = CatalogMetaRouting.pageURL(for: working)
        if let html = try? await BrowserHTMLClient.shared.fetchHTML(from: page),
           let year = ReleaseYearParser.romsFunReleaseYear(fromHTML: html) {
            return DatePatch(
                game: working.withReleaseYear(year),
                filled: true,
                clearedSuspect: false,
                sourceName: "RomsFun"
            )
        }

        return DatePatch(
            game: working,
            filled: false,
            clearedSuspect: isSuspectCorrection,
            sourceName: nil
        )
    }

    // MARK: - TheGamesDB

    private static func theGamesDBCover(for game: GameResult) async -> GameResult? {
        guard await TheGamesDBClient.shared.isConfigured,
              !CoverArtParser.isUsableCover(game.thumbnailURL),
              let hit = await TheGamesDBClient.shared.lookup(for: game),
              let cover = hit.coverURL,
              CoverArtParser.isUsableCover(cover) else {
            return nil
        }
        return game.updatingThumbnail(cover, forPageURL: CatalogMetaRouting.pageURL(for: game))
    }

    private static func theGamesDBYear(for game: GameResult, allowCorrection: Bool) async -> Int? {
        guard await TheGamesDBClient.shared.isConfigured else { return nil }
        let wantYear = game.releaseYear == nil
            || (allowCorrection && CatalogMetaRouting.needsReleaseYearRefresh(game))
        guard wantYear else { return nil }
        guard let hit = await TheGamesDBClient.shared.lookup(for: game) else { return nil }
        return hit.releaseYear
    }

    // MARK: - LaunchBox

    private static func launchBoxCover(for game: GameResult) async -> GameResult? {
        guard await LaunchBoxMetadataClient.shared.isConfigured,
              !CoverArtParser.isUsableCover(game.thumbnailURL),
              let hit = await LaunchBoxMetadataClient.shared.lookup(for: game),
              let cover = hit.coverURL,
              CoverArtParser.isUsableCover(cover) else {
            return nil
        }
        return game.updatingThumbnail(cover, forPageURL: CatalogMetaRouting.pageURL(for: game))
    }

    private static func launchBoxYear(for game: GameResult, allowCorrection: Bool) async -> Int? {
        guard await LaunchBoxMetadataClient.shared.isConfigured else { return nil }
        let wantYear = game.releaseYear == nil
            || (allowCorrection && CatalogMetaRouting.needsReleaseYearRefresh(game))
        guard wantYear else { return nil }
        guard let hit = await LaunchBoxMetadataClient.shared.lookup(for: game) else { return nil }
        return hit.releaseYear
    }

    // MARK: - HTTP scrape

    private static func httpReleaseYear(for game: GameResult) async -> Int? {
        let page = CatalogMetaRouting.pageURL(for: game)
        guard let html = try? await HTTPClient.fetchString(from: page) else { return nil }
        return ReleaseYearParser.detect(fromHTML: html)
    }
}
