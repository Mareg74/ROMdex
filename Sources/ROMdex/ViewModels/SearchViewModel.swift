import AppKit
import Foundation
import WebKit

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard !suppressQueryWatch, query != oldValue else { return }
            scheduleLiveSearch()
        }
    }
    @Published var selectedPlatforms: Set<Platform> = [] {
        didSet { scheduleFilterRefresh(platformChanged: oldValue != selectedPlatforms) }
    }
    @Published var selectedRegions: Set<GameRegion> = [] {
        didSet { scheduleFilterRefresh(platformChanged: false) }
    }
    @Published var results: [GameResult] = []
    @Published var selectedResult: GameResult?
    @Published var isSearching = false
    @Published var statusMessage = "Recherchez un jeu par titre, plateforme et région."
    @Published var sourceErrors: [String] = []
    @Published private(set) var hiddenSourceSites: Set<String> = AppPreferences.hiddenSourceSites

    let historyStore = SearchHistoryStore()
    private let searchEngine = SearchEngine()
    private let resultsCache = SearchResultsCache.shared
    private let pageCache = PagePreviewCache.shared

    private var cachedResults: [GameResult] = []
    private var cachedQuery = ""
    private var cachedPlatforms: Set<Platform> = []
    /// Résultats catalogue pour la requête courante (sans le web), pour affinage O(n).
    private var localCatalogHits: [GameResult] = []
    private var localPassTask: Task<Void, Never>?
    private var networkSearchTask: Task<Void, Never>?
    private var filterRefreshTask: Task<Void, Never>?
    private var suppressFilterRefresh = false
    private var suppressQueryWatch = false

    private static let liveResultCap = 120

    init() {
        Task.detached(priority: .utility) {
            CatalogLocalSearch.warmup()
        }
    }

    /// Entrée / bouton : lance le web tout de suite (sans attendre le debounce).
    func search() {
        localPassTask?.cancel()
        networkSearchTask?.cancel()
        runSearch(immediateNetwork: true)
    }

    func refreshForFilterChange(platformChanged: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if platformChanged {
            localCatalogHits = []
            runSearch(immediateNetwork: true)
            return
        }

        applyFilters(recordHistory: true, liveTyping: false)
    }

    func togglePlatform(_ platform: Platform) {
        if selectedPlatforms.contains(platform) {
            selectedPlatforms.remove(platform)
        } else {
            selectedPlatforms.insert(platform)
        }
    }

    func toggleRegion(_ region: GameRegion) {
        if selectedRegions.contains(region) {
            selectedRegions.remove(region)
        } else {
            selectedRegions.insert(region)
        }
    }

    func clearPlatforms() {
        selectedPlatforms.removeAll()
    }

    func clearRegions() {
        selectedRegions.removeAll()
    }

    /// Sites présents dans les résultats bruts courants (avant filtre sources).
    var availableSourceSites: [String] {
        GameResult.availableSourceSiteNames(in: cachedResults)
    }

    func toggleSourceSiteVisibility(_ siteName: String) {
        AppPreferences.toggleSourceSiteVisibility(siteName)
        hiddenSourceSites = AppPreferences.hiddenSourceSites
        applyFilters(recordHistory: false, liveTyping: false)
    }

    func showAllSourceSites() {
        AppPreferences.showAllSourceSites()
        hiddenSourceSites = AppPreferences.hiddenSourceSites
        applyFilters(recordHistory: false, liveTyping: false)
    }

    func select(_ result: GameResult) {
        selectedResult = result
        preloadPreview(for: result)
    }

    func preloadPreview(for result: GameResult) {
        for source in result.sources.prefix(5) {
            pageCache.preload(source.pageURL)
        }
    }

    func openInBrowser(_ result: GameResult? = nil) {
        guard let url = (result ?? selectedResult)?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func applyHistory(_ entry: SearchHistoryEntry) {
        suppressQueryWatch = true
        suppressFilterRefresh = true
        query = entry.query
        selectedPlatforms = entry.platformsSet
        selectedRegions = entry.regionsSet
        suppressFilterRefresh = false
        suppressQueryWatch = false
        objectWillChange.send()
        search()
    }

    func clearAllCaches() {
        localPassTask?.cancel()
        networkSearchTask?.cancel()
        AppCache.clearAll()
        cachedResults = []
        localCatalogHits = []
        cachedQuery = ""
        cachedPlatforms = []
        statusMessage = "Cache vidé — mémoire libérée."
    }

    /// Retire les erreurs Cloudflare RomsFun (après déblocage réussi).
    func clearRomsFunSourceErrors() {
        sourceErrors.removeAll { error in
            let lower = error.lowercased()
            guard lower.contains("romsfun") else { return false }
            return lower.contains("bloqué")
                || lower.contains("anti-bot")
                || lower.contains("cloudflare")
                || lower.contains("blocked")
        }
    }

    func clearHistory() {
        historyStore.clear()
        statusMessage = "Historique de recherche supprimé."
    }

    // MARK: - Live search

    /// Ne fait aucun travail lourd dans le didSet : la frappe reste fluide.
    private func scheduleLiveSearch() {
        localPassTask?.cancel()
        networkSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetIdleState()
            return
        }

        let platforms = selectedPlatforms
        let previousQuery = cachedQuery
        let previousPlatforms = cachedPlatforms
        let previousLocal = localCatalogHits
        let previousCached = cachedResults

        localPassTask = Task { @MainActor in
            // Laisse le NSTextField peindre la lettre avant tout travail UI.
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

            if let snapshot = self.resultsCache.lookup(query: trimmed, platforms: platforms) {
                self.cachedResults = snapshot.results
                self.localCatalogHits = snapshot.results
                self.cachedQuery = snapshot.query
                self.cachedPlatforms = snapshot.platforms
                self.sourceErrors = snapshot.errors
                self.isSearching = false
                self.applyFilters(recordHistory: false, liveTyping: false)
                return
            }

            let tokens = Self.queryTokens(trimmed)
            let canRefine =
                !previousQuery.isEmpty
                && trimmed.lowercased().hasPrefix(previousQuery.lowercased())
                && trimmed.count > previousQuery.count
                && platforms == previousPlatforms

            let local: [GameResult]
            if canRefine {
                local = previousLocal.filter { Self.titleMatches($0.title, tokens: tokens) }
            } else {
                // Hors du MainActor : le 1er chargement d’index ne bloque pas la frappe.
                let q = trimmed
                let p = platforms
                local = await Task.detached(priority: .userInitiated) {
                    CatalogLocalSearch.search(query: q, platforms: p)
                }.value
            }

            let refinedExisting = previousCached.filter {
                Self.titleMatches($0.title, tokens: tokens)
                    && (platforms.isEmpty || platforms.contains($0.platform))
            }

            let merged = CatalogMerger.mergePreservingEnrichment(
                previous: local,
                scraped: refinedExisting
            ).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

            guard !Task.isCancelled else { return }
            guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

            self.localCatalogHits = local
            self.cachedResults = merged
            self.cachedQuery = trimmed
            self.cachedPlatforms = platforms
            self.isSearching = true
            self.applyFilters(recordHistory: false, liveTyping: true)

            if merged.isEmpty {
                self.statusMessage = "Recherche…"
            } else {
                self.statusMessage = "\(merged.count) dans le catalogue — recherche en ligne…"
            }

            self.networkSearchTask?.cancel()
            self.networkSearchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                let current = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == trimmed else { return }
                await self.fetchOnlineAndMerge(query: trimmed)
            }
        }
    }

    private func runSearch(immediateNetwork: Bool) {
        localPassTask?.cancel()
        networkSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetIdleState()
            statusMessage = "Saisissez un titre de jeu."
            return
        }

        if let snapshot = resultsCache.lookup(query: trimmed, platforms: selectedPlatforms) {
            cachedResults = snapshot.results
            localCatalogHits = snapshot.results
            cachedQuery = snapshot.query
            cachedPlatforms = snapshot.platforms
            sourceErrors = snapshot.errors
            isSearching = false
            applyFilters(recordHistory: true, liveTyping: false)
            return
        }

        let platforms = selectedPlatforms
        let local = CatalogLocalSearch.search(query: trimmed, platforms: platforms)
        localCatalogHits = local
        cachedResults = local
        cachedQuery = trimmed
        cachedPlatforms = platforms
        isSearching = true
        applyFilters(recordHistory: false, liveTyping: false)

        if local.isEmpty {
            statusMessage = "Recherche en ligne sur \(searchEngine.adapters.count) sources…"
        } else {
            statusMessage = "\(local.count) dans le catalogue — recherche en ligne…"
        }

        networkSearchTask = Task { @MainActor in
            if !immediateNetwork {
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                let current = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == trimmed else { return }
            }
            await self.fetchOnlineAndMerge(query: trimmed)
        }
    }

    private func resetIdleState() {
        localPassTask?.cancel()
        networkSearchTask?.cancel()
        isSearching = false
        cachedResults = []
        localCatalogHits = []
        cachedQuery = ""
        cachedPlatforms = []
        results = []
        selectedResult = nil
        sourceErrors = []
        statusMessage = "Recherchez un jeu par titre, plateforme et région."
    }

    private func fetchOnlineAndMerge(query trimmed: String) async {
        let platforms = selectedPlatforms

        if let snapshot = resultsCache.lookup(query: trimmed, platforms: platforms) {
            cachedResults = snapshot.results
            localCatalogHits = snapshot.results
            cachedQuery = snapshot.query
            cachedPlatforms = snapshot.platforms
            sourceErrors = snapshot.errors
            isSearching = false
            applyFilters(recordHistory: true, liveTyping: false)
            return
        }

        isSearching = true
        let localSnapshot = localCatalogHits.isEmpty || cachedQuery != trimmed
            ? CatalogLocalSearch.search(query: trimmed, platforms: platforms)
            : localCatalogHits
        let outcome = await searchEngine.search(query: trimmed, platforms: platforms)

        let current = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == trimmed, !Task.isCancelled else { return }

        let merged = CatalogMerger.mergePreservingEnrichment(
            previous: localSnapshot,
            scraped: outcome.results
        ).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        localCatalogHits = localSnapshot
        cachedResults = merged
        cachedQuery = trimmed
        cachedPlatforms = platforms
        sourceErrors = outcome.errors

        resultsCache.store(
            query: trimmed,
            platforms: platforms,
            results: merged,
            errors: outcome.errors
        )

        applyFilters(recordHistory: true, liveTyping: false)
        isSearching = false
    }

    private func scheduleFilterRefresh(platformChanged: Bool) {
        guard !suppressFilterRefresh else { return }

        filterRefreshTask?.cancel()
        filterRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            refreshForFilterChange(platformChanged: platformChanged)
        }
    }

    private func applyFilters(recordHistory: Bool, liveTyping: Bool) {
        var filtered = cachedResults

        if !selectedPlatforms.isEmpty {
            filtered = filtered.filter { selectedPlatforms.contains($0.platform) }
        }

        if !selectedRegions.isEmpty {
            filtered = filtered.compactMap { $0.restrictingSources(to: selectedRegions) }
        }

        if !hiddenSourceSites.isEmpty {
            filtered = filtered.compactMap { $0.restrictingSources(hidingSiteNames: hiddenSourceSites) }
        }

        let totalCount = filtered.count
        if liveTyping, filtered.count > Self.liveResultCap {
            filtered = Array(filtered.prefix(Self.liveResultCap))
        }

        results = filtered

        if recordHistory, !cachedQuery.isEmpty {
            historyStore.record(
                query: cachedQuery,
                platforms: selectedPlatforms,
                regions: selectedRegions
            )
        }

        if filtered.isEmpty {
            if cachedResults.isEmpty {
                if isSearching {
                    statusMessage = "Recherche en cours…"
                } else {
                    statusMessage = sourceErrors.isEmpty
                        ? "Aucun résultat trouvé."
                        : "Aucun résultat. Certaines sources ont échoué."
                }
            } else {
                statusMessage = "Aucun résultat pour ces filtres."
            }
            if !liveTyping {
                selectedResult = nil
            } else if let selected = selectedResult,
                      !cachedResults.contains(where: { $0.id == selected.id }) {
                selectedResult = nil
            }
            return
        }

        let filterNote = filterSummaryNote
        if liveTyping {
            if totalCount > Self.liveResultCap {
                statusMessage = "\(totalCount) jeu(x)\(filterNote) — affinage…"
            } else {
                statusMessage = "\(totalCount) jeu(x)\(filterNote) — affinage en ligne…"
            }
            // Pendant la frappe : ne pas forcer la sélection ni précharger les WebViews.
            if let selected = selectedResult,
               !filtered.contains(where: { $0.id == selected.id }) {
                selectedResult = nil
            }
            return
        }

        if isSearching {
            statusMessage = "\(totalCount) jeu(x)\(filterNote) — affinage en ligne…"
        } else {
            statusMessage = "\(totalCount) jeu(x) trouvé(s)\(filterNote)."
        }

        let stillVisible = selectedResult.map { selected in
            filtered.contains(where: { $0.id == selected.id })
        } ?? false
        if !stillVisible {
            selectedResult = filtered.first
        }

        preloadTopPreviews(from: filtered)
    }

    private var filterSummaryNote: String {
        var parts: [String] = []
        if !selectedPlatforms.isEmpty {
            parts.append(selectedPlatforms.map(\.displayName).sorted().joined(separator: ", "))
        }
        if !selectedRegions.isEmpty {
            parts.append(selectedRegions.map(\.displayName).sorted().joined(separator: ", "))
        }
        if !hiddenSourceSites.isEmpty {
            parts.append("\(hiddenSourceSites.count) source(s) masquée(s)")
        }
        guard !parts.isEmpty else { return "" }
        return " (" + parts.joined(separator: " · ") + ")"
    }

    private func preloadTopPreviews(from results: [GameResult]) {
        let urls = results.prefix(5).map(\.pageURL)
        pageCache.preload(urls: Array(urls))
    }

    private static func queryTokens(_ query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func titleMatches(_ title: String, tokens: [String]) -> Bool {
        let haystack = title.lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
