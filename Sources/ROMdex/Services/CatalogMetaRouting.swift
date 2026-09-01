import Foundation

/// Routage méta catalogue (RomsFun = WebKit).
enum CatalogMetaRouting {
    static func pageURL(for result: GameResult) -> URL {
        if let romsFun = result.sources.first(where: {
            $0.pageURL.host?.lowercased().contains("romsfun.com") == true
        }) {
            return romsFun.pageURL
        }
        return result.pageURL
    }

    static func needsBrowser(for result: GameResult) -> Bool {
        pageURL(for: result).host?.lowercased().contains("romsfun.com") == true
    }

    /// Année absente du catalogue (rebuild manuel).
    static func needsMissingReleaseYear(_ result: GameResult) -> Bool {
        result.releaseYear == nil
    }

    /// Année manquante ou suspecte (ex. date WordPress 2015+ sur console rétro).
    static func needsReleaseYearRefresh(_ result: GameResult) -> Bool {
        if needsMissingReleaseYear(result) { return true }
        guard let year = result.releaseYear, year >= 2015 else { return false }
        return hasRomsFun(result) && isRetroPlatform(result.platform)
    }

    static func needsMetadataRefresh(_ result: GameResult) -> Bool {
        if needsReleaseYearRefresh(result) { return true }
        if result.genre == nil { return true }
        return false
    }

    private static func hasRomsFun(_ result: GameResult) -> Bool {
        result.sources.contains { $0.pageURL.host?.lowercased().contains("romsfun.com") == true }
    }

    private static func isRetroPlatform(_ platform: Platform) -> Bool {
        switch platform {
        case .switchPlatform, .n3ds, .wiiU, .ps3:
            return false
        default:
            return true
        }
    }
}
