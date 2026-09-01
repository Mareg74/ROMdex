import Foundation
import WebKit

enum AppPreferences {
    static let clearCacheOnQuitKey = "clearCacheOnQuit"
    static let catalogCheckOnLaunchKey = "catalogCheckOnLaunch"
    static let catalogCheckIntervalHoursKey = "catalogCheckIntervalHours"
    static let catalogScrapeParallelKey = "catalogScrapeParallel"
    static let catalogScrapeParallelLimitKey = "catalogScrapeParallelLimit"
    static let theGamesDBAPIKeyKey = "theGamesDBAPIKey"
    static let theGamesDBEnabledKey = "theGamesDBEnabled"
    static let launchBoxMetadataEnabledKey = "launchBoxMetadataEnabled"
    static let launchBoxMetadataPathKey = "launchBoxMetadataPath"
    static let hiddenSourceSitesKey = "hiddenSourceSites"
    static let hiddenRegionsKey = "hiddenRegions"

    /// Sites masqués dans les listes (catalogue, recherche, favoris). Vide = tout affiché.
    static var hiddenSourceSites: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: hiddenSourceSitesKey) ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenSourceSitesKey)
        }
    }

    static func isSourceSiteVisible(_ siteName: String) -> Bool {
        !hiddenSourceSites.contains(siteName)
    }

    static func toggleSourceSiteVisibility(_ siteName: String) {
        var hidden = hiddenSourceSites
        if hidden.contains(siteName) {
            hidden.remove(siteName)
        } else {
            hidden.insert(siteName)
        }
        hiddenSourceSites = hidden
    }

    static func showAllSourceSites() {
        hiddenSourceSites = []
    }

    /// Régions masquées dans le catalogue. Vide = toutes affichées.
    static var hiddenRegions: Set<GameRegion> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: hiddenRegionsKey) ?? []
            return Set(array.compactMap(GameRegion.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(
                Array(newValue).map(\.rawValue).sorted(),
                forKey: hiddenRegionsKey
            )
        }
    }

    static func isRegionVisible(_ region: GameRegion) -> Bool {
        !hiddenRegions.contains(region)
    }

    static func toggleRegionVisibility(_ region: GameRegion) {
        var hidden = hiddenRegions
        if hidden.contains(region) {
            hidden.remove(region)
        } else {
            hidden.insert(region)
        }
        hiddenRegions = hidden
    }

    static func showAllRegions() {
        hiddenRegions = []
    }

    static var launchBoxMetadataEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: launchBoxMetadataEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: launchBoxMetadataEnabledKey) }
    }

    static var launchBoxMetadataPath: String? {
        get {
            let value = UserDefaults.standard.string(forKey: launchBoxMetadataPathKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(newValue, forKey: launchBoxMetadataPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchBoxMetadataPathKey)
            }
        }
    }

    static var theGamesDBEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: theGamesDBEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: theGamesDBEnabledKey) }
    }

    static var theGamesDBAPIKey: String? {
        get {
            let value = UserDefaults.standard.string(forKey: theGamesDBAPIKeyKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(newValue, forKey: theGamesDBAPIKeyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: theGamesDBAPIKeyKey)
            }
        }
    }

    static var clearCacheOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: clearCacheOnQuitKey) }
        set { UserDefaults.standard.set(newValue, forKey: clearCacheOnQuitKey) }
    }

    /// Vérifier les catalogues au démarrage (si l’intervalle est écoulé). Défaut : oui.
    static var catalogCheckOnLaunch: Bool {
        get {
            if UserDefaults.standard.object(forKey: catalogCheckOnLaunchKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: catalogCheckOnLaunchKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: catalogCheckOnLaunchKey) }
    }

    /// Intervalle minimum entre deux vérifications automatiques (heures). Défaut : 24.
    static var catalogCheckIntervalHours: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: catalogCheckIntervalHoursKey)
            return value > 0 ? value : 24
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: catalogCheckIntervalHoursKey) }
    }

    /// Scraper plusieurs consoles en parallèle (sinon une à la fois). Défaut : non.
    static var catalogScrapeParallel: Bool {
        get { UserDefaults.standard.bool(forKey: catalogScrapeParallelKey) }
        set { UserDefaults.standard.set(newValue, forKey: catalogScrapeParallelKey) }
    }

    /// Nombre max de consoles scrapées en même temps si parallèle. Défaut : 3.
    static var catalogScrapeParallelLimit: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: catalogScrapeParallelLimitKey)
            return value > 0 ? min(value, 6) : 3
        }
        set { UserDefaults.standard.set(min(6, max(2, newValue)), forKey: catalogScrapeParallelLimitKey) }
    }

    static let fetchParallelEnabledKey = "fetchParallelEnabled"
    static let fetchConcurrencyPerHostKey = "fetchConcurrencyPerHost"

    /// Requêtes HTTP parallèles par site (recherche + catalogue). Défaut : oui.
    static var fetchParallelEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: fetchParallelEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: fetchParallelEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: fetchParallelEnabledKey) }
    }

    /// Nombre max de requêtes simultanées vers un même hôte. Défaut : 4.
    static var fetchConcurrencyPerHost: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: fetchConcurrencyPerHostKey)
            return value > 0 ? min(value, 8) : 4
        }
        set { UserDefaults.standard.set(min(8, max(1, newValue)), forKey: fetchConcurrencyPerHostKey) }
    }
}

enum AppCache {
    /// Vide les caches d’affichage (recherche, aperçus WebKit, RAM catalogue).
    /// Ne touche pas aux JSON catalogue ni au cache disque des jaquettes.
    @MainActor
    static func clearAll() {
        PagePreviewCache.shared.clear()
        SearchResultsCache.shared.clear()
        CatalogCache.shared.clearMemory()
        URLCache.shared.removeAllCachedResponses()
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }
}
