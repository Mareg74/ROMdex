import Foundation

/// Job de scrape catalogue (file d’attente, non annulé au changement de console).
struct CatalogScrapeJob: Identifiable, Equatable {
    enum Phase: Equatable {
        case queued
        case running
    }

    let id: UUID
    let platform: Platform
    var phase: Phase
    var liveProgress: CatalogLiveProgress?
    /// Jeux cumulés découverts pendant ce scrape (toutes sources).
    var discoveredCount: Int
    /// `true` = actualisation demandée (toast +N) ; `false` = premier chargement.
    let announceDelta: Bool
    /// Sources déjà terminées (reprise après interruption).
    let skipAdapterIds: Set<String>

    init(
        id: UUID = UUID(),
        platform: Platform,
        phase: Phase = .queued,
        liveProgress: CatalogLiveProgress? = nil,
        discoveredCount: Int = 0,
        announceDelta: Bool,
        skipAdapterIds: Set<String> = []
    ) {
        self.id = id
        self.platform = platform
        self.phase = phase
        self.liveProgress = liveProgress
        self.discoveredCount = discoveredCount
        self.announceDelta = announceDelta
        self.skipAdapterIds = skipAdapterIds
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var selectedPlatform: Platform? {
        didSet {
            guard selectedPlatform != oldValue else { return }
            selectedResult = nil
            if let selectedPlatform {
                presentPlatform(selectedPlatform)
            } else {
                results = []
                rawResults = []
            }
        }
    }

    @Published var sortOrder: CatalogSortOrder = .titleAsc {
        didSet { applySortAndFilter() }
    }

    @Published var results: [GameResult] = []
    @Published var selectedResult: GameResult?
    @Published var isEnriching = false
    @Published var liveProgress: CatalogLiveProgress?
    @Published var sourceErrors: [String] = []
    @Published var filterText = "" {
        didSet { applySortAndFilter() }
    }
    @Published private(set) var hiddenSourceSites: Set<String> = AppPreferences.hiddenSourceSites
    @Published private(set) var hiddenRegions: Set<GameRegion> = AppPreferences.hiddenRegions
    @Published private(set) var updateToasts: [CatalogToast] = []
    @Published private(set) var isCheckingUpdates = false
    /// File visible : jobs en cours + en attente (spinners empilés).
    @Published private(set) var scrapeJobs: [CatalogScrapeJob] = []

    var isLoading: Bool { !scrapeJobs.isEmpty }

    /// Premier chargement de la console sélectionnée (pas encore de jeux).
    var showsBlockingLoader: Bool {
        guard results.isEmpty, let platform = selectedPlatform else { return false }
        return scrapeJobs.contains { $0.platform == platform }
    }

    private let cache = CatalogCache.shared
    private let updateMonitor = CatalogUpdateMonitor.shared
    private var rawResults: [GameResult] = []
    private var catalogUpdatedAt: Date?
    private var enrichTask: Task<Void, Never>?
    private var thumbnailRebuildTask: Task<Void, Never>?
    private var releaseYearRebuildTask: Task<Void, Never>?
    private var selectionEnrichTask: Task<Void, Never>?
    private var isSelectionEnriching = false
    /// Sauvegarde la barre dates/vignettes pendant l’enrichissement d’une fiche sélectionnée.
    private var catalogRebuildProgressBackup: CatalogLiveProgress?
    /// Nombre de scrapes réellement en vol (emplacements parallèles).
    private var activeScrapeCount = 0
    /// Tâches détachées par job (pour annulation).
    private var scrapeTasks: [UUID: Task<Void, Never>] = [:]
    /// Contexte des scrapes en vol (snapshot partiel + métadonnées pour flush immédiat).
    private var runningScrapeContexts: [UUID: RunningScrapeContext] = [:]
    /// Jobs déjà flushés au clic annuler (évite les toasts en double).
    private var flushedScrapeJobIDs: Set<UUID> = []
    /// Toast +N même si le job était déjà en file pour un premier chargement.
    private var pendingAnnounceDelta: [Platform: Bool] = [:]
    private var restoredInterruptedScrapeToasts = false

    func hasCatalogUpdate(for platform: Platform) -> Bool {
        updateMonitor.flaggedPlatforms.contains(platform)
    }

    func hasInterruptedScrape(for platform: Platform) -> Bool {
        let fingerprint = CatalogScrapeCheckpointStore.adapterFingerprint(
            adapterIds: CatalogEngine().adapterIds
        )
        return CatalogScrapeCheckpointStore.hasInterruptedScrape(
            for: platform,
            adapterFingerprint: fingerprint
        )
    }

    /// Résumé de la console affichée (jeux filtrés, métadonnées, date de sauvegarde).
    var platformStatusSummary: String {
        guard let platform = selectedPlatform else {
            return "Choisissez une console pour charger le catalogue."
        }
        return statusLine(for: platform)
    }

    /// Total de jeux sur toutes les consoles (catalogue disque + mémoire).
    @Published private(set) var totalCatalogGameCount = 0

    func refreshTotalCatalogGameCount() {
        var total = 0
        for platform in Platform.allCases {
            total += cache.lookup(platform)?.results.count ?? 0
        }
        totalCatalogGameCount = total
    }

    /// Vérification automatique (démarrage) ou forcée (menu).
    func checkCatalogUpdates(force: Bool = false) {
        if force {
            updateMonitor.checkAll(includeRomsFun: true)
        } else {
            updateMonitor.checkIfNeeded(force: false)
        }
        Task { @MainActor in
            isCheckingUpdates = true
            while updateMonitor.isChecking {
                objectWillChange.send()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            isCheckingUpdates = false
            objectWillChange.send()
            if force, let message = updateMonitor.statusMessage {
                showToast(list: "Vérification mises à jour", message)
            } else if !updateMonitor.flaggedPlatforms.isEmpty {
                let list = Self.toastListLabel(for: updateMonitor.flaggedPlatforms)
                let detail = updateMonitor.flaggedPlatforms.count == 1
                    ? "Catalogue potentiellement mis à jour."
                    : "\(updateMonitor.flaggedPlatforms.count) catalogues potentiellement mis à jour."
                showToast(list: list, detail)
            }
        }
    }

    private lazy var catalogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var platforms: [Platform] { Platform.allCases }

    func selectPlatform(_ platform: Platform) {
        selectedPlatform = platform
    }

    func select(_ result: GameResult) {
        selectedResult = result
        for source in result.sources.prefix(5) {
            PagePreviewCache.shared.preload(source.pageURL)
        }
        selectionEnrichTask?.cancel()
        selectionEnrichTask = Task { @MainActor in
            await enrichSelectionPriority(result)
        }
    }

    /// Sites présents dans le catalogue brut courant (avant filtre sources).
    var availableSourceSites: [String] {
        GameResult.availableSourceSiteNames(in: rawResults)
    }

    /// Régions présentes dans le catalogue brut courant (avant filtre régions).
    var availableRegions: [GameRegion] {
        GameResult.availableRegions(in: rawResults)
    }

    func toggleSourceSiteVisibility(_ siteName: String) {
        AppPreferences.toggleSourceSiteVisibility(siteName)
        hiddenSourceSites = AppPreferences.hiddenSourceSites
        applySortAndFilter()
    }

    func showAllSourceSites() {
        AppPreferences.showAllSourceSites()
        hiddenSourceSites = AppPreferences.hiddenSourceSites
        applySortAndFilter()
    }

    func toggleRegionVisibility(_ region: GameRegion) {
        AppPreferences.toggleRegionVisibility(region)
        hiddenRegions = AppPreferences.hiddenRegions
        applySortAndFilter()
    }

    func showAllRegions() {
        AppPreferences.showAllRegions()
        hiddenRegions = AppPreferences.hiddenRegions
        applySortAndFilter()
    }

    /// Affiche le cache local sans couper les scrapes ; enqueue si pas de JSON.
    private func presentPlatform(_ platform: Platform) {
        if !isCatalogRebuildRunning {
            enrichTask?.cancel()
            isEnriching = false
        }

        if let cached = cache.lookup(platform), !cached.results.isEmpty {
            let hadJunk = cached.results.contains { result in
                result.sources.contains { source in
                    source.thumbnailURL.map(CoverArtParser.isLikelyJunkCover) ?? false
                }
            }
            let cleaned = cached.results.map { $0.strippingJunkThumbnails() }
            rawResults = cleaned
            // Erreurs transitoires (annulation, anti-bot) : ne pas les resservir.
            let cleanedErrors = Self.displaySourceErrors(cached.errors)
            sourceErrors = cleanedErrors
            catalogUpdatedAt = cache.lastUpdated(for: platform)
            applySortAndFilter()
            if hadJunk || cleanedErrors.count != cached.errors.count {
                cache.store(
                    platform,
                    outcome: SearchOutcome(results: cleaned, errors: cleanedErrors)
                )
            }
            return
        }

        rawResults = []
        results = []
        sourceErrors = []
        catalogUpdatedAt = nil
        promptAndEnqueueScrape(platform, announceDelta: false)
    }

    /// Re-scrape la console sélectionnée en conservant jaquettes / métadonnées déjà OK.
    func reload() {
        guard let platform = selectedPlatform else { return }
        if let cached = cache.lookup(platform), !cached.results.isEmpty {
            rawResults = cached.results
            sourceErrors = cached.errors.filter { !Self.shouldHideSourceError($0) }
            catalogUpdatedAt = cache.lastUpdated(for: platform)
            applySortAndFilter()
        }
        promptAndEnqueueScrape(platform, announceDelta: true)
    }

    /// Reprend un scrape interrompu sans boîte de dialogue (depuis le toast ou la sidebar).
    func resumeInterruptedScrape(for platform: Platform, toastID: UUID? = nil) {
        if let toastID {
            dismissToast(id: toastID)
        }
        let fingerprint = CatalogScrapeCheckpointStore.adapterFingerprint(
            adapterIds: CatalogEngine().adapterIds
        )
        if let checkpoint = CatalogScrapeCheckpointStore.load(platform),
           checkpoint.interrupted,
           CatalogScrapeCheckpointStore.hasInterruptedScrape(
               for: platform,
               adapterFingerprint: fingerprint
           ) {
            enqueueScrape(
                platform,
                announceDelta: true,
                skipAdapterIds: Set(checkpoint.completedAdapterIds)
            )
        } else {
            enqueueScrape(platform, announceDelta: true)
        }
    }

    /// Affiche les toasts de reprise pour les scrapes interrompus lors d’une session précédente.
    func restoreInterruptedScrapeToastsIfNeeded() {
        guard !restoredInterruptedScrapeToasts else { return }
        restoredInterruptedScrapeToasts = true

        let fingerprint = CatalogScrapeCheckpointStore.adapterFingerprint(
            adapterIds: CatalogEngine().adapterIds
        )
        for platform in CatalogScrapeCheckpointStore.interruptedPlatforms(adapterFingerprint: fingerprint) {
            showInterruptedScrapeResumeToast(for: platform)
        }
    }

    /// Reconstruit depuis zéro (efface le JSON puis re-scrape — perd les enrichissements).
    func rebuild() {
        guard let platform = selectedPlatform else { return }
        CatalogScrapeCheckpointStore.clear(platform)
        cache.remove(platform)
        rawResults = []
        results = []
        selectedResult = nil
        sourceErrors = []
        catalogUpdatedAt = nil
        scrapeJobs.removeAll { $0.platform == platform && $0.phase == .queued }
        enqueueScrape(platform, announceDelta: true)
    }

    /// Reconstruction dates / vignettes en cours (distinct de l’enrichissement auto).
    var isCatalogRebuildRunning: Bool {
        releaseYearRebuildTask != nil || thumbnailRebuildTask != nil
    }

    /// Progression affichable (préservée pendant l’enrichissement d’une fiche).
    var activeLiveProgress: CatalogLiveProgress? {
        liveProgress ?? (isCatalogRebuildRunning ? catalogRebuildProgressBackup : nil)
    }

    /// Demande reprise ou redémarrage puis lance la reconstruction des vignettes.
    func promptAndRebuildMissingThumbnails() {
        let platformsWithGames = collectPlatformsWithGames()
        guard !platformsWithGames.isEmpty else {
            showToast(list: "Vignettes · toutes consoles", "Catalogue vide.")
            return
        }

        let fingerprint = CatalogRebuildCheckpointStore.catalogFingerprint(outcomes: platformsWithGames)
        let resumeFrom: Int

        if let checkpoint = CatalogRebuildCheckpointStore.load(.thumbnails) {
            switch CatalogRebuildCheckpointStore.prompt(
                kind: .thumbnails,
                checkpoint: checkpoint,
                catalogFingerprint: fingerprint
            ) {
            case .resume:
                resumeFrom = checkpoint.processedIndex
            case .restart:
                resumeFrom = 0
            case .cancel:
                return
            }
        } else {
            resumeFrom = 0
        }

        rebuildMissingThumbnails(resumeFrom: resumeFrom, catalogFingerprint: fingerprint)
    }

    /// Demande reprise ou redémarrage puis lance la reconstruction des dates.
    func promptAndRebuildReleaseYears() {
        let platformsWithGames = collectPlatformsWithGames()
        guard !platformsWithGames.isEmpty else {
            showToast(list: "Dates · toutes consoles", "Catalogue vide.")
            return
        }

        let fingerprint = CatalogRebuildCheckpointStore.catalogFingerprint(outcomes: platformsWithGames)
        let resumeFrom: Int

        if let checkpoint = CatalogRebuildCheckpointStore.load(.dates) {
            switch CatalogRebuildCheckpointStore.prompt(
                kind: .dates,
                checkpoint: checkpoint,
                catalogFingerprint: fingerprint
            ) {
            case .resume:
                resumeFrom = checkpoint.processedIndex
            case .restart:
                resumeFrom = 0
            case .cancel:
                return
            }
        } else {
            resumeFrom = 0
        }

        rebuildReleaseYears(resumeFrom: resumeFrom, catalogFingerprint: fingerprint)
    }

    /// Arrête la reconstruction dates ou vignettes en cours (point de reprise conservé).
    func cancelActiveCatalogRebuild() {
        if releaseYearRebuildTask != nil {
            releaseYearRebuildTask?.cancel()
            releaseYearRebuildTask = nil
            catalogRebuildProgressBackup = nil
            isEnriching = false
            liveProgress = nil
            showToast(list: "Dates · toutes consoles", "Opération interrompue — reprise possible au prochain lancement.")
            return
        }
        if thumbnailRebuildTask != nil {
            thumbnailRebuildTask?.cancel()
            thumbnailRebuildTask = nil
            catalogRebuildProgressBackup = nil
            isEnriching = false
            liveProgress = nil
            showToast(list: "Vignettes · toutes consoles", "Opération interrompue — reprise possible au prochain lancement.")
        }
    }

    private func collectPlatformsWithGames() -> [(Platform, SearchOutcome)] {
        Platform.allCases.compactMap { platform in
            guard let outcome = cache.lookup(platform), !outcome.results.isEmpty else { return nil }
            return (platform, outcome)
        }
    }

    /// Nettoie les placeholders et comble les jaquettes manquantes (Libretro + sites pour la console affichée).
    private func rebuildMissingThumbnails(resumeFrom: Int, catalogFingerprint: String) {
        thumbnailRebuildTask?.cancel()
        releaseYearRebuildTask?.cancel()

        thumbnailRebuildTask = Task { @MainActor in
            var totalGamesInDatabase = 0
            var totalMissing = 0
            var platformsWithGames: [(Platform, SearchOutcome)] = []

            for platform in Platform.allCases {
                guard !Task.isCancelled else { return }
                guard let outcome = cache.lookup(platform), !outcome.results.isEmpty else { continue }

                totalGamesInDatabase += outcome.results.count
                totalMissing += outcome.results.filter {
                    !CoverArtParser.isUsableCover($0.thumbnailURL)
                }.count
                platformsWithGames.append((platform, outcome))
            }

            guard !Task.isCancelled else { return }

            guard totalMissing > 0 else {
                CatalogRebuildCheckpointStore.clear(.thumbnails)
                showToast(list: "Vignettes · toutes consoles", "Rien à compléter.")
                return
            }

            isEnriching = true
            dismissToast()
            liveProgress = CatalogLiveProgress(
                phaseLabel: "Vignettes…",
                siteName: nil,
                urlText: nil,
                gameTitle: nil,
                detail: "Préparation…",
                activeSites: [],
                discoveredCount: 0,
                progressIndex: resumeFrom,
                progressTotal: totalGamesInDatabase
            )
            catalogRebuildProgressBackup = liveProgress

            var filled = 0
            var cleanedPlatforms = 0
            var processed = 0
            var lastSavedProcessed = resumeFrom
            var inProgressPlatform: Platform?
            var inProgressGames: [GameResult]?
            var inProgressErrors: [String]?

            @MainActor
            func reportThumbnailProgress(
                phaseLabel: String,
                siteName: String?,
                platform: Platform,
                gameTitle: String
            ) {
                liveProgress = CatalogLiveProgress(
                    phaseLabel: phaseLabel,
                    siteName: siteName,
                    urlText: nil,
                    gameTitle: gameTitle,
                    detail: platform.displayName,
                    activeSites: [],
                    discoveredCount: filled,
                    progressIndex: processed,
                    progressTotal: totalGamesInDatabase
                )
                catalogRebuildProgressBackup = liveProgress
            }

            @MainActor
            func persistThumbnailCheckpoint(
                platform: Platform? = nil,
                games: [GameResult]? = nil,
                errors: [String]? = nil
            ) {
                CatalogRebuildCheckpointStore.saveInterrupted(
                    kind: .thumbnails,
                    processedIndex: processed,
                    totalGames: totalGamesInDatabase,
                    catalogFingerprint: catalogFingerprint
                )
                if let platform, let games, let errors {
                    cache.store(platform, outcome: SearchOutcome(results: games, errors: errors))
                }
                lastSavedProcessed = processed
            }

            defer {
                if Task.isCancelled {
                    if let inProgressPlatform,
                       let inProgressGames,
                       let inProgressErrors {
                        persistThumbnailCheckpoint(
                            platform: inProgressPlatform,
                            games: inProgressGames,
                            errors: inProgressErrors
                        )
                        if selectedPlatform == inProgressPlatform {
                            rawResults = inProgressGames
                            sourceErrors = inProgressErrors.filter { !Self.shouldHideSourceError($0) }
                            catalogUpdatedAt = cache.lastUpdated(for: inProgressPlatform)
                            applySortAndFilter()
                        }
                    } else {
                        persistThumbnailCheckpoint()
                    }
                } else {
                    CatalogRebuildCheckpointStore.clear(.thumbnails)
                }
            }

            for (platform, outcome) in platformsWithGames {
                guard !Task.isCancelled else { return }

                let beforeJunk = outcome.results
                let stripped = beforeJunk.map { $0.strippingJunkThumbnails() }
                let didStrip = zip(stripped, beforeJunk).contains { a, b in
                    a.sources.map(\.thumbnailURL) != b.sources.map(\.thumbnailURL)
                }
                if didStrip { cleanedPlatforms += 1 }

                var games = stripped
                var platformChanged = didStrip
                var thumbnailWork: [IndexedGame] = []
                inProgressPlatform = platform
                inProgressGames = games
                inProgressErrors = outcome.errors

                for index in games.indices {
                    guard !Task.isCancelled else { return }
                    processed += 1
                    let game = games[index]

                    if processed <= resumeFrom {
                        reportThumbnailProgress(
                            phaseLabel: "Vignettes…",
                            siteName: nil,
                            platform: platform,
                            gameTitle: game.title
                        )
                        if processed - lastSavedProcessed >= 50 {
                            persistThumbnailCheckpoint()
                        }
                        continue
                    }

                    guard !CoverArtParser.isUsableCover(game.thumbnailURL) else {
                        reportThumbnailProgress(
                            phaseLabel: "Vignettes…",
                            siteName: nil,
                            platform: platform,
                            gameTitle: game.title
                        )
                        if processed - lastSavedProcessed >= 50 {
                            persistThumbnailCheckpoint(
                                platform: platformChanged ? platform : nil,
                                games: platformChanged ? games : nil,
                                errors: platformChanged ? outcome.errors : nil
                            )
                            platformChanged = false
                        }
                        continue
                    }

                    thumbnailWork.append(IndexedGame(index: index, game: game))
                }

                let concurrency = catalogRebuildConcurrency
                var workOffset = 0
                while workOffset < thumbnailWork.count {
                    guard !Task.isCancelled else { return }
                    await yieldToSelectionEnrichment()

                    let waveEnd = min(workOffset + concurrency, thumbnailWork.count)
                    let wave = Array(thumbnailWork[workOffset ..< waveEnd])
                    workOffset = waveEnd

                    let patches: [CatalogRebuildEnricher.ThumbnailPatch?]
                    if concurrency <= 1 {
                        var sequential: [CatalogRebuildEnricher.ThumbnailPatch?] = []
                        sequential.reserveCapacity(wave.count)
                        for item in wave {
                            let patch = await CatalogRebuildEnricher.fetchThumbnail(
                                for: item.game,
                                platform: platform
                            )
                            sequential.append(patch)
                        }
                        patches = sequential
                    } else {
                        patches = await ParallelFetch.map(wave) { item in
                            await CatalogRebuildEnricher.fetchThumbnail(for: item.game, platform: platform)
                        }
                    }

                    for (item, patch) in zip(wave, patches) {
                        guard let patch else { continue }
                        games[item.index] = patch.game
                        platformChanged = true
                        filled += 1
                        inProgressGames = games
                        reportThumbnailProgress(
                            phaseLabel: "Vignettes…",
                            siteName: patch.sourceName,
                            platform: platform,
                            gameTitle: patch.game.title
                        )
                    }

                    if processed - lastSavedProcessed >= 20 {
                        persistThumbnailCheckpoint(
                            platform: platformChanged ? platform : nil,
                            games: platformChanged ? games : nil,
                            errors: platformChanged ? outcome.errors : nil
                        )
                        platformChanged = false
                    }
                }

                if platformChanged {
                    cache.store(
                        platform,
                        outcome: SearchOutcome(results: games, errors: outcome.errors)
                    )
                }

                inProgressPlatform = nil
                inProgressGames = nil
                inProgressErrors = nil

                if selectedPlatform == platform {
                    rawResults = games
                    sourceErrors = outcome.errors.filter { !Self.shouldHideSourceError($0) }
                    catalogUpdatedAt = cache.lastUpdated(for: platform)
                    applySortAndFilter()
                }
            }

            guard !Task.isCancelled else { return }

            thumbnailRebuildTask = nil
            catalogRebuildProgressBackup = nil

            var message = "+\(filled) complétée(s)"
            if cleanedPlatforms > 0 {
                message += " · \(cleanedPlatforms) console(s) nettoyée(s)"
            }
            showToast(list: "Vignettes · toutes consoles", message)

            // Console affichée : compléter encore via RomHustler / RomsFun si besoin.
            if selectedPlatform != nil, !rawResults.isEmpty {
                enrichMetadata()
            } else {
                isEnriching = false
                liveProgress = nil
            }
        }
    }

    /// Complète les années absentes ou corrige les dates suspectes (ex. publication WordPress).
    private func rebuildReleaseYears(resumeFrom: Int, catalogFingerprint: String) {
        enrichTask?.cancel()
        thumbnailRebuildTask?.cancel()
        releaseYearRebuildTask?.cancel()

        releaseYearRebuildTask = Task { @MainActor in
            var totalTargets = 0
            var totalGamesInDatabase = 0
            var platformsWithGames: [(Platform, SearchOutcome)] = []

            for platform in Platform.allCases {
                guard !Task.isCancelled else { return }
                guard let outcome = cache.lookup(platform), !outcome.results.isEmpty else { continue }

                totalGamesInDatabase += outcome.results.count
                platformsWithGames.append((platform, outcome))
                totalTargets += outcome.results.filter {
                    CatalogMetaRouting.needsReleaseYearRefresh($0)
                }.count
            }

            guard !Task.isCancelled else { return }

            guard totalTargets > 0 else {
                CatalogRebuildCheckpointStore.clear(.dates)
                showToast(list: "Dates · toutes consoles", "Rien à compléter ni corriger.")
                return
            }

            isEnriching = true
            dismissToast()
            liveProgress = CatalogLiveProgress(
                phaseLabel: "Dates de sortie…",
                siteName: nil,
                urlText: nil,
                gameTitle: nil,
                detail: "Préparation…",
                activeSites: [],
                discoveredCount: 0,
                progressIndex: resumeFrom,
                progressTotal: totalGamesInDatabase
            )
            catalogRebuildProgressBackup = liveProgress

            var filled = 0
            var cleared = 0
            var platformsTouched = 0
            var processed = 0
            var lastSavedProcessed = resumeFrom
            var inProgressPlatform: Platform?
            var inProgressGames: [GameResult]?
            var inProgressErrors: [String]?

            @MainActor
            func reportDateRebuildProgress(
                siteName: String?,
                platform: Platform,
                gameTitle: String
            ) {
                liveProgress = CatalogLiveProgress(
                    phaseLabel: "Dates de sortie…",
                    siteName: siteName,
                    urlText: nil,
                    gameTitle: gameTitle,
                    detail: platform.displayName,
                    activeSites: [],
                    discoveredCount: filled,
                    progressIndex: processed,
                    progressTotal: totalGamesInDatabase
                )
                catalogRebuildProgressBackup = liveProgress
            }

            @MainActor
            func persistDateCheckpoint(
                platform: Platform? = nil,
                games: [GameResult]? = nil,
                errors: [String]? = nil
            ) {
                CatalogRebuildCheckpointStore.saveInterrupted(
                    kind: .dates,
                    processedIndex: processed,
                    totalGames: totalGamesInDatabase,
                    catalogFingerprint: catalogFingerprint
                )
                if let platform, let games, let errors {
                    cache.store(platform, outcome: SearchOutcome(results: games, errors: errors))
                }
                lastSavedProcessed = processed
            }

            defer {
                if Task.isCancelled {
                    if let inProgressPlatform,
                       let inProgressGames,
                       let inProgressErrors {
                        persistDateCheckpoint(
                            platform: inProgressPlatform,
                            games: inProgressGames,
                            errors: inProgressErrors
                        )
                        if selectedPlatform == inProgressPlatform {
                            rawResults = inProgressGames
                            sourceErrors = inProgressErrors.filter { !Self.shouldHideSourceError($0) }
                            catalogUpdatedAt = cache.lastUpdated(for: inProgressPlatform)
                            applySortAndFilter()
                        }
                    } else {
                        persistDateCheckpoint()
                    }
                } else {
                    CatalogRebuildCheckpointStore.clear(.dates)
                    isEnriching = false
                    liveProgress = nil
                }
            }

            for (platform, outcome) in platformsWithGames {
                guard !Task.isCancelled else { return }

                var games = outcome.results
                var platformChanged = false
                var httpDateWork: [IndexedGame] = []
                var browserDateWork: [IndexedGame] = []
                inProgressPlatform = platform
                inProgressGames = games
                inProgressErrors = outcome.errors

                for index in games.indices {
                    guard !Task.isCancelled else { return }
                    processed += 1
                    let game = games[index]

                    if processed <= resumeFrom {
                        reportDateRebuildProgress(
                            siteName: nil,
                            platform: platform,
                            gameTitle: game.title
                        )
                        if processed - lastSavedProcessed >= 50 {
                            persistDateCheckpoint()
                        }
                        continue
                    }

                    guard CatalogMetaRouting.needsReleaseYearRefresh(game) else {
                        reportDateRebuildProgress(
                            siteName: nil,
                            platform: platform,
                            gameTitle: game.title
                        )
                        if processed - lastSavedProcessed >= 50 {
                            persistDateCheckpoint(
                                platform: platformChanged ? platform : nil,
                                games: platformChanged ? games : nil,
                                errors: platformChanged ? outcome.errors : nil
                            )
                            platformChanged = false
                        }
                        continue
                    }

                    let item = IndexedGame(index: index, game: game)
                    if CatalogMetaRouting.needsBrowser(for: game) {
                        browserDateWork.append(item)
                    } else {
                        httpDateWork.append(item)
                    }
                }

                let concurrency = catalogRebuildConcurrency
                var httpOffset = 0
                while httpOffset < httpDateWork.count {
                    guard !Task.isCancelled else { return }
                    await yieldToSelectionEnrichment()

                    let waveEnd = min(httpOffset + concurrency, httpDateWork.count)
                    let wave = Array(httpDateWork[httpOffset ..< waveEnd])
                    httpOffset = waveEnd

                    let patches: [CatalogRebuildEnricher.DatePatch]
                    if concurrency <= 1 {
                        var sequential: [CatalogRebuildEnricher.DatePatch] = []
                        sequential.reserveCapacity(wave.count)
                        for item in wave {
                            sequential.append(await CatalogRebuildEnricher.fetchReleaseYearHTTP(for: item.game))
                        }
                        patches = sequential
                    } else {
                        patches = await ParallelFetch.map(wave) { item in
                            await CatalogRebuildEnricher.fetchReleaseYearHTTP(for: item.game)
                        }
                    }

                    for (item, patch) in zip(wave, patches) {
                        games[item.index] = patch.game
                        if patch.filled {
                            platformChanged = true
                            filled += 1
                        } else if patch.clearedSuspect {
                            platformChanged = true
                            cleared += 1
                        }
                        inProgressGames = games
                        reportDateRebuildProgress(
                            siteName: patch.sourceName,
                            platform: platform,
                            gameTitle: patch.game.title
                        )
                    }

                    if processed - lastSavedProcessed >= 20 {
                        persistDateCheckpoint(
                            platform: platformChanged ? platform : nil,
                            games: platformChanged ? games : nil,
                            errors: platformChanged ? outcome.errors : nil
                        )
                        platformChanged = false
                    }
                }

                for item in browserDateWork {
                    guard !Task.isCancelled else { return }
                    await yieldToSelectionEnrichment()

                    let patch = await CatalogRebuildEnricher.fetchReleaseYearBrowser(for: item.game)
                    games[item.index] = patch.game
                    if patch.filled {
                        platformChanged = true
                        filled += 1
                    } else if patch.clearedSuspect {
                        platformChanged = true
                        cleared += 1
                    }
                    inProgressGames = games
                    reportDateRebuildProgress(
                        siteName: patch.sourceName ?? "RomsFun",
                        platform: platform,
                        gameTitle: patch.game.title
                    )

                    if processed - lastSavedProcessed >= 20 {
                        persistDateCheckpoint(
                            platform: platformChanged ? platform : nil,
                            games: platformChanged ? games : nil,
                            errors: platformChanged ? outcome.errors : nil
                        )
                        platformChanged = false
                    }
                }

                if platformChanged {
                    platformsTouched += 1
                    cache.store(
                        platform,
                        outcome: SearchOutcome(results: games, errors: outcome.errors)
                    )
                }

                inProgressPlatform = nil
                inProgressGames = nil
                inProgressErrors = nil

                if selectedPlatform == platform {
                    rawResults = games
                    sourceErrors = outcome.errors.filter { !Self.shouldHideSourceError($0) }
                    catalogUpdatedAt = cache.lastUpdated(for: platform)
                    applySortAndFilter()
                }
            }

            guard !Task.isCancelled else { return }

            releaseYearRebuildTask = nil
            catalogRebuildProgressBackup = nil

            var message = "+\(filled) complétée(s)"
            if cleared > 0 {
                message += " · \(cleared) erronée(s) effacée(s)"
            }
            if platformsTouched > 0 {
                message += " · \(platformsTouched) console(s)"
            }
            if filled == 0, cleared == 0 {
                message = "Aucune date fiable trouvée."
            } else if filled == 0 {
                message = "\(cleared) date(s) erronée(s) effacée(s)"
            }
            showToast(list: "Dates · toutes consoles", message)
        }
    }

    /// Enfile toutes les consoles (sans annuler les jobs déjà en cours).
    func refreshAllCatalogs() {
        for platform in Platform.allCases {
            enqueueScrape(platform, announceDelta: true)
        }
        showToast(list: "Actualisation · toutes consoles", "\(scrapeJobs.count) console(s) en file.")
    }

    /// Annule un job (en cours ou en attente).
    func cancelScrape(jobID: UUID) {
        let wasRunning = scrapeJobs.first(where: { $0.id == jobID })?.phase == .running
        if wasRunning {
            flushPartialScrape(jobID: jobID)
        }
        scrapeTasks.removeValue(forKey: jobID)?.cancel()
        if let platform = scrapeJobs.first(where: { $0.id == jobID })?.platform {
            pendingAnnounceDelta[platform] = nil
        }
        scrapeJobs.removeAll { $0.id == jobID }
        if wasRunning {
            activeScrapeCount = max(0, activeScrapeCount - 1)
        }
        refreshCatalogSummary()
        pumpScrapeQueue()
    }

    /// Annule toute la file d’actualisation.
    func cancelAllScrapes() {
        for job in scrapeJobs where job.phase == .running {
            flushPartialScrape(jobID: job.id)
        }
        for task in scrapeTasks.values {
            task.cancel()
        }
        scrapeTasks.removeAll()
        scrapeJobs.removeAll()
        pendingAnnounceDelta.removeAll()
        activeScrapeCount = 0
        refreshCatalogSummary()
    }

    // MARK: - File d’attente scrape

    private struct ScrapeCompletion: Sendable {
        let jobID: UUID
        let platform: Platform
        let announce: Bool
        let merged: [GameResult]
        let errors: [String]
        let keysBefore: Set<String>
        let userCancelled: Bool
        let completedAdapterIds: Set<String>
        let totalAdapterCount: Int
    }

    private struct PreparedScrape: Sendable {
        let jobID: UUID
        let platform: Platform
        let announce: Bool
        let previous: [GameResult]
        let keysBefore: Set<String>
        let skipAdapterIds: Set<String>
    }

    private struct RunningScrapeContext {
        let prepared: PreparedScrape
        var latestResponse: CatalogBrowseResponse?
    }

    private var scrapeConcurrencyLimit: Int {
        AppPreferences.catalogScrapeParallel
            ? AppPreferences.catalogScrapeParallelLimit
            : 1
    }

    private func enqueueScrape(
        _ platform: Platform,
        announceDelta: Bool,
        skipAdapterIds: Set<String> = []
    ) {
        if scrapeJobs.contains(where: { $0.platform == platform }) {
            if announceDelta {
                pendingAnnounceDelta[platform] = true
            }
            return
        }

        pendingAnnounceDelta[platform] = announceDelta
        scrapeJobs.append(
            CatalogScrapeJob(
                platform: platform,
                announceDelta: announceDelta,
                skipAdapterIds: skipAdapterIds
            )
        )
        pumpScrapeQueue()
    }

    private func promptAndEnqueueScrape(_ platform: Platform, announceDelta: Bool) {
        let fingerprint = CatalogScrapeCheckpointStore.adapterFingerprint(
            adapterIds: CatalogEngine().adapterIds
        )
        if let checkpoint = CatalogScrapeCheckpointStore.load(platform),
           checkpoint.interrupted,
           CatalogScrapeCheckpointStore.hasInterruptedScrape(
               for: platform,
               adapterFingerprint: fingerprint
           ) {
            switch CatalogScrapeCheckpointStore.prompt(
                platform: platform,
                checkpoint: checkpoint,
                adapterFingerprint: fingerprint
            ) {
            case .resume:
                enqueueScrape(
                    platform,
                    announceDelta: announceDelta,
                    skipAdapterIds: Set(checkpoint.completedAdapterIds)
                )
            case .restart:
                enqueueScrape(platform, announceDelta: announceDelta)
            case .cancel:
                return
            }
        } else {
            enqueueScrape(platform, announceDelta: announceDelta)
        }
    }

    /// Remplit les emplacements libres (1 en séquentiel, jusqu’à N en parallèle).
    private func pumpScrapeQueue() {
        let limit = scrapeConcurrencyLimit
        while activeScrapeCount < limit,
              let jobIndex = scrapeJobs.firstIndex(where: { $0.phase == .queued }) {
            let prepared = prepareJob(at: jobIndex)
            activeScrapeCount += 1
            let onProgress = makeProgressHandler(for: prepared.jobID)
            let jobID = prepared.jobID
            runningScrapeContexts[jobID] = RunningScrapeContext(prepared: prepared, latestResponse: nil)
            let onPartial: @Sendable (CatalogBrowseResponse) -> Void = { [weak self] response in
                Task { @MainActor in
                    self?.notePartialScrape(jobID: jobID, response: response)
                }
            }
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                let response = await CatalogEngine().browse(
                    platform: prepared.platform,
                    skipAdapterIds: prepared.skipAdapterIds,
                    onProgress: onProgress,
                    onPartial: onPartial
                )
                let merged = CatalogMerger.mergePreservingEnrichment(
                    previous: prepared.previous,
                    scraped: response.outcome.results
                )
                let completion = ScrapeCompletion(
                    jobID: prepared.jobID,
                    platform: prepared.platform,
                    announce: prepared.announce,
                    merged: merged,
                    errors: response.outcome.errors,
                    keysBefore: prepared.keysBefore,
                    userCancelled: Task.isCancelled,
                    completedAdapterIds: Set(response.completedAdapterIds),
                    totalAdapterCount: response.totalAdapterCount
                )
                await self?.finalizeScrape(completion)
            }
            scrapeTasks[jobID] = task
        }
    }

    private func prepareJob(at jobIndex: Int) -> PreparedScrape {
        scrapeJobs[jobIndex].phase = .running
        scrapeJobs[jobIndex].liveProgress = nil
        scrapeJobs[jobIndex].discoveredCount = 0
        let platform = scrapeJobs[jobIndex].platform
        let announce = pendingAnnounceDelta[platform] ?? scrapeJobs[jobIndex].announceDelta
        let previous = cache.lookup(platform)?.results ?? []
        return PreparedScrape(
            jobID: scrapeJobs[jobIndex].id,
            platform: platform,
            announce: announce,
            previous: previous,
            keysBefore: Set(previous.map(\.deduplicationKey)),
            skipAdapterIds: scrapeJobs[jobIndex].skipAdapterIds
        )
    }

    /// Termine un scrape (normal ou annulé) en sauvegardant toujours les données collectées.
    private func finalizeScrape(_ completion: ScrapeCompletion) async {
        scrapeTasks.removeValue(forKey: completion.jobID)
        runningScrapeContexts.removeValue(forKey: completion.jobID)
        let alreadyFlushed = flushedScrapeJobIDs.remove(completion.jobID) != nil

        let jobStillQueued = scrapeJobs.contains(where: { $0.id == completion.jobID })
        let hadNewData = !Set(completion.merged.map(\.deduplicationKey))
            .subtracting(completion.keysBefore)
            .isEmpty
        let shouldPersist = !completion.merged.isEmpty
            || !completion.errors.isEmpty
            || hadNewData

        if shouldPersist {
            persistScrapeResult(completion)
            await updateMonitor.refreshBaseline(for: completion.platform)
        }

        updateScrapeCheckpoint(completion)

        if jobStillQueued {
            finishScrape(completion, showCancelToast: !alreadyFlushed && completion.userCancelled)
            activeScrapeCount = max(0, activeScrapeCount - 1)
            pumpScrapeQueue()
        } else if completion.userCancelled {
            applyPartialScrapeToUI(completion, showToast: !alreadyFlushed)
        } else {
            activeScrapeCount = max(0, activeScrapeCount - 1)
            pumpScrapeQueue()
        }
    }

    private func notePartialScrape(jobID: UUID, response: CatalogBrowseResponse) {
        runningScrapeContexts[jobID]?.latestResponse = response
    }

    /// Écrit sur disque immédiatement au clic « Arrêter » (sans attendre la fin des requêtes HTTP).
    private func flushPartialScrape(jobID: UUID) {
        guard !flushedScrapeJobIDs.contains(jobID),
              let context = runningScrapeContexts[jobID] else { return }

        let prepared = context.prepared
        let response = context.latestResponse ?? CatalogBrowseResponse(
            outcome: SearchOutcome(results: [], errors: []),
            completedAdapterIds: Array(prepared.skipAdapterIds),
            totalAdapterCount: CatalogEngine().adapterIds.count
        )
        let merged = CatalogMerger.mergePreservingEnrichment(
            previous: prepared.previous,
            scraped: response.outcome.results
        )
        let completion = ScrapeCompletion(
            jobID: jobID,
            platform: prepared.platform,
            announce: prepared.announce,
            merged: merged,
            errors: response.outcome.errors,
            keysBefore: prepared.keysBefore,
            userCancelled: true,
            completedAdapterIds: Set(response.completedAdapterIds),
            totalAdapterCount: response.totalAdapterCount
        )

        persistScrapeResult(completion)
        updateScrapeCheckpoint(completion)
        flushedScrapeJobIDs.insert(jobID)

        if selectedPlatform == prepared.platform {
            rawResults = merged
            sourceErrors = Self.displaySourceErrors(completion.errors)
            catalogUpdatedAt = cache.lastUpdated(for: prepared.platform)
            applySortAndFilter()
        }

        showCancelledScrapeToast(completion)
        Task { await updateMonitor.refreshBaseline(for: prepared.platform) }
    }

    private func showCancelledScrapeToast(_ completion: ScrapeCompletion) {
        let added = Set(completion.merged.map(\.deduplicationKey))
            .subtracting(completion.keysBefore)
            .count
        if canResumeInterruptedScrape(completion) {
            if added > 0 {
                showToast(
                    list: completion.platform.displayName,
                    "Actualisation interrompue · +\(added) jeu(x) sauvegardé(s).",
                    resumePlatform: completion.platform
                )
            } else {
                showToast(
                    list: completion.platform.displayName,
                    "Actualisation interrompue · catalogue sauvegardé.",
                    resumePlatform: completion.platform
                )
            }
        } else if added > 0 {
            showToast(
                list: completion.platform.displayName,
                "Actualisation interrompue · +\(added) jeu(x) sauvegardé(s)."
            )
        } else {
            showToast(
                list: completion.platform.displayName,
                "Actualisation interrompue · catalogue sauvegardé."
            )
        }
    }

    private func showInterruptedScrapeResumeToast(for platform: Platform) {
        guard !updateToasts.contains(where: { $0.resumePlatform == platform }) else { return }
        guard let checkpoint = CatalogScrapeCheckpointStore.load(platform),
              checkpoint.interrupted else { return }

        let done = checkpoint.completedAdapterIds.count
        let total = max(checkpoint.totalAdapters, 1)
        let remaining = max(0, total - done)
        showToast(
            list: platform.displayName,
            "Actualisation interrompue · \(done)/\(total) sources terminées (\(remaining) restante(s)).",
            resumePlatform: platform
        )
    }

    private func canResumeInterruptedScrape(_ completion: ScrapeCompletion) -> Bool {
        let done = completion.completedAdapterIds.count
        let total = completion.totalAdapterCount
        guard done > 0, done < total else { return false }
        let fingerprint = CatalogScrapeCheckpointStore.adapterFingerprint(
            adapterIds: CatalogEngine().adapterIds
        )
        return CatalogScrapeCheckpointStore.hasInterruptedScrape(
            for: completion.platform,
            adapterFingerprint: fingerprint
        )
    }

    /// Met à jour l’UI après annulation (job déjà retiré de la file).
    private func applyPartialScrapeToUI(_ completion: ScrapeCompletion, showToast: Bool = true) {
        if selectedPlatform == completion.platform {
            rawResults = completion.merged
            sourceErrors = Self.displaySourceErrors(completion.errors)
            catalogUpdatedAt = cache.lastUpdated(for: completion.platform)
            applySortAndFilter()
        }

        guard showToast else { return }

        let added = Set(completion.merged.map(\.deduplicationKey))
            .subtracting(completion.keysBefore)
            .count
        guard added > 0 || selectedPlatform == completion.platform else { return }

        showCancelledScrapeToast(completion)
    }

    private func updateScrapeCheckpoint(_ completion: ScrapeCompletion) {
        if completion.userCancelled {
            let done = completion.completedAdapterIds.count
            let total = completion.totalAdapterCount
            guard done > 0, done < total else {
                if done >= total {
                    CatalogScrapeCheckpointStore.clear(completion.platform)
                }
                return
            }
            let fingerprint = CatalogScrapeCheckpointStore.adapterFingerprint(
                adapterIds: CatalogEngine().adapterIds
            )
            CatalogScrapeCheckpointStore.save(
                CatalogScrapeCheckpointStore.Checkpoint(
                    platformRawValue: completion.platform.rawValue,
                    completedAdapterIds: completion.completedAdapterIds.sorted(),
                    totalAdapters: total,
                    adapterSetFingerprint: fingerprint,
                    interrupted: true,
                    updatedAt: .now
                ),
                for: completion.platform
            )
            objectWillChange.send()
        } else {
            CatalogScrapeCheckpointStore.clear(completion.platform)
        }
    }

    private func persistScrapeResult(_ completion: ScrapeCompletion) {
        let errors = Self.displaySourceErrors(completion.errors)
        let stored = SearchOutcome(results: completion.merged, errors: errors)
        cache.store(completion.platform, outcome: stored)
        refreshTotalCatalogGameCount()
    }

    private func finishScrape(_ completion: ScrapeCompletion, showCancelToast: Bool = false) {
        scrapeJobs.removeAll { $0.id == completion.jobID }
        pendingAnnounceDelta[completion.platform] = nil

        if selectedPlatform == completion.platform {
            rawResults = completion.merged
            sourceErrors = Self.displaySourceErrors(completion.errors)
            catalogUpdatedAt = cache.lastUpdated(for: completion.platform)
            applySortAndFilter()
            if !completion.userCancelled {
                enrichMetadata()
            }
        }

        let added = Set(completion.merged.map(\.deduplicationKey)).subtracting(completion.keysBefore).count
        if completion.userCancelled {
            if showCancelToast {
                showCancelledScrapeToast(completion)
            }
        } else if completion.announce {
            if added > 0 {
                showToast(list: completion.platform.displayName, "+\(added) nouveau(x) jeu(x).")
            } else {
                showToast(list: completion.platform.displayName, "Catalogue à jour (données conservées).")
            }
        }
    }

    private func makeProgressHandler(for jobID: UUID) -> @Sendable (CatalogProgressEvent, [String]) -> Void {
        { [weak self] event, activeSites in
            Task { @MainActor in
                guard let self else { return }
                let progress = CatalogLiveProgress.from(event: event, activeSites: activeSites)
                if let index = self.scrapeJobs.firstIndex(where: { $0.id == jobID }) {
                    self.scrapeJobs[index].liveProgress = progress
                    if progress.discoveredCount > self.scrapeJobs[index].discoveredCount {
                        self.scrapeJobs[index].discoveredCount = progress.discoveredCount
                    }
                }
            }
        }
    }

    /// Vide seulement la RAM catalogue (les JSON restent).
    func clearMemoryCache() {
        cache.clearMemory()
    }

    /// Vide RAM + fichiers JSON catalogue.
    func clearDiskCatalog() {
        cache.clear()
        rawResults = []
        results = []
        catalogUpdatedAt = nil
        refreshCatalogSummary()
    }

    /// Après déblocage RomsFun : nettoie les erreurs et reprend les jaquettes, sans re-scrape.
    func onRomsFunUnlocked() {
        clearRomsFunSourceErrors()
        guard selectedPlatform != nil, !rawResults.isEmpty else { return }
        enrichMetadata()
    }

    /// Retire les erreurs Cloudflare RomsFun (UI + tous les JSON console).
    func clearRomsFunSourceErrors() {
        sourceErrors.removeAll(where: Self.shouldHideSourceError)

        for platform in Platform.allCases {
            if platform == selectedPlatform, !rawResults.isEmpty {
                cache.store(
                    platform,
                    outcome: SearchOutcome(results: rawResults, errors: sourceErrors)
                )
                continue
            }

            guard let outcome = cache.lookup(platform), !outcome.results.isEmpty else { continue }
            let cleaned = outcome.errors.filter { !Self.shouldHideSourceError($0) }
            guard cleaned.count != outcome.errors.count else { continue }
            cache.store(
                platform,
                outcome: SearchOutcome(results: outcome.results, errors: cleaned)
            )
        }
    }

    private static func displaySourceErrors(_ errors: [String]) -> [String] {
        errors.filter { !shouldHideSourceError($0) }
    }

    private static func shouldHideSourceError(_ error: String) -> Bool {
        if ScrapeErrorFilter.isTransientStoredError(error) { return true }
        return isRomsFunBlockError(error)
    }

    private static func isRomsFunBlockError(_ error: String) -> Bool {
        let lower = error.lowercased()
        guard lower.contains("romsfun") else { return false }
        return lower.contains("bloqué")
            || lower.contains("anti-bot")
            || lower.contains("cloudflare")
            || lower.contains("blocked")
    }

    // MARK: - Export / import

    func exportCatalog() {
        CatalogTransfer.presentExportPanel()
        if let message = CatalogTransferNotifier.shared.message {
            showToast(list: "Export catalogue", message)
            CatalogTransferNotifier.shared.message = nil
        }
    }

    func importCatalog(merge: Bool) {
        CatalogTransfer.presentImportPanel(mode: merge ? .merge : .replace) { [weak self] summary in
            guard let self else { return }
            self.reloadFromDiskAfterImport()
            let modeLabel = merge ? "fusionnés" : "importés"
            var text = "\(summary.platformsImported) console(s) \(modeLabel)"
            if summary.gamesAdded > 0 {
                text += merge
                    ? " · +\(summary.gamesAdded) jeu(x)"
                    : " · \(summary.gamesAdded) jeu(x)"
            }
            if summary.coversImported > 0 {
                text += " · \(summary.coversImported) vignette(s)"
            }
            self.showToast(list: "Import catalogue", text)
        }
    }

    private func reloadFromDiskAfterImport() {
        cache.clearMemory()
        CatalogUpdateMonitor.shared.reloadFromDisk()
        if let platform = selectedPlatform {
            if let cached = cache.lookup(platform) {
                rawResults = cached.results
                sourceErrors = cached.errors.filter { !Self.shouldHideSourceError($0) }
                catalogUpdatedAt = cache.lastUpdated(for: platform)
                applySortAndFilter()
                enrichMetadata()
            } else {
                rawResults = []
                results = []
                catalogUpdatedAt = nil
            }
        }
        refreshTotalCatalogGameCount()
        objectWillChange.send()
    }

    func showToast(list: String, _ message: String, resumePlatform: Platform? = nil) {
        let toast = CatalogToast(list: list, message: message, resumePlatform: resumePlatform)
        updateToasts.insert(toast, at: 0)
    }

    private static func toastListLabel(for platforms: some Collection<Platform>) -> String {
        let names = platforms.map(\.displayName).sorted()
        switch names.count {
        case 0:
            return "Catalogue"
        case 1:
            return names[0]
        case 2 ... 3:
            return names.joined(separator: ", ")
        default:
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        }
    }

    func dismissToast(id: UUID) {
        updateToasts.removeAll { $0.id == id }
    }

    /// Efface toutes les notifications (ex. début d’un rebuild).
    func dismissToast() {
        updateToasts.removeAll()
    }

    private func applySortAndFilter() {
        var filtered = rawResults
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            filtered = filtered.filter {
                $0.title.lowercased().contains(needle)
                    || ($0.genre?.lowercased().contains(needle) ?? false)
                    || $0.sources.contains { $0.siteName.lowercased().contains(needle) }
            }
        }
        if !hiddenRegions.isEmpty {
            filtered = filtered.compactMap { $0.restrictingSources(hidingRegions: hiddenRegions) }
        }
        if !hiddenSourceSites.isEmpty {
            filtered = filtered.compactMap { $0.restrictingSources(hidingSiteNames: hiddenSourceSites) }
        }
        results = sortOrder.sorted(filtered)

        if let selected = selectedResult,
           !results.contains(where: { $0.id == selected.id }) {
            selectedResult = nil
        }

        refreshCatalogSummary()
    }

    private func refreshCatalogSummary() {
        refreshTotalCatalogGameCount()
    }

    private func statusLine(for platform: Platform) -> String {
        let knownYears = results.filter { $0.releaseYear != nil }.count
        let knownGenres = results.filter { $0.genre != nil }.count
        let hasTextFilter = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSourceFilter = !hiddenSourceSites.isEmpty
        let hasRegionFilter = !hiddenRegions.isEmpty
        var filterNote = ""
        if hasTextFilter || hasSourceFilter || hasRegionFilter {
            var notes: [String] = []
            if hasTextFilter { notes.append("texte") }
            if hasRegionFilter {
                notes.append("\(hiddenRegions.count) région(s) masquée(s)")
            }
            if hasSourceFilter {
                let hidden = hiddenSourceSites.count
                notes.append("\(hidden) source(s) masquée(s)")
            }
            filterNote = " (filtre : \(notes.joined(separator: " · ")))"
        }

        var parts = ["\(results.count) jeu(x)"]
        if knownYears > 0 { parts.append("\(knownYears) avec année") }
        if knownGenres > 0 { parts.append("\(knownGenres) avec genre") }
        parts.append(platform.displayName)

        var line = parts.joined(separator: " — ") + filterNote
        if let date = catalogUpdatedAt {
            line += " · sauvé \(catalogDateFormatter.string(from: date))"
        }
        return line
    }

    /// Complète années + genres manquants (échantillon) et jaquettes absentes (par vagues).
    private func enrichMetadata() {
        enrichTask?.cancel()

        let stripped = rawResults.map { $0.strippingJunkThumbnails() }
        if stripped.contains(where: { result in
            let idx = rawResults.firstIndex(where: { $0.id == result.id })
            guard let idx else { return false }
            return result.sources.map(\.thumbnailURL) != rawResults[idx].sources.map(\.thumbnailURL)
        }) {
            rawResults = stripped
            persistCatalogAndRefreshUI()
        }

        let needsMeta = rawResults.filter { CatalogMetaRouting.needsMetadataRefresh($0) }
        let needsCover = !romHustlerSourcesNeedingCover(in: rawResults).isEmpty
            || !romsFunSourcesNeedingCover(in: rawResults).isEmpty
            || rawResults.contains {
                !CoverArtParser.isUsableCover($0.thumbnailURL)
                    && ($0.platform.libretroSystemFolder != nil || $0.platform.gamesDBPlatformID != nil)
            }
        guard !needsMeta.isEmpty || needsCover else {
            refreshCatalogSummary()
            return
        }

        enrichTask = Task { @MainActor in
            isEnriching = true
            let report: @Sendable (String, String, URL) -> Void = { [weak self] site, title, url in
                Task { @MainActor in
                    self?.liveProgress = CatalogLiveProgress(
                        phaseLabel: "Enrichissement…",
                        siteName: site,
                        urlText: url.absoluteString,
                        gameTitle: title,
                        detail: nil,
                        activeSites: [],
                        discoveredCount: 0
                    )
                }
            }

            // Phase 1 : TheGamesDB API (prioritaire, rapide).
            await enrichTheGamesDBBatch(
                metaCandidates: Array(needsMeta.prefix(50)),
                includeCoverless: true,
                allowYearCorrection: true,
                report: report
            )

            // Phase 1b : LaunchBox Metadata local.
            await enrichLaunchBoxBatch(
                metaCandidates: Array(needsMeta.prefix(50)),
                includeCoverless: true,
                allowYearCorrection: true,
                report: report
            )

            let stillNeedsMeta = rawResults.filter { CatalogMetaRouting.needsMetadataRefresh($0) }
            let metaTargets = prioritizeSelected(
                Array(stillNeedsMeta.prefix(50)),
                key: \.deduplicationKey
            )

            var years: [URL: Int] = [:]
            var genres: [URL: String] = [:]
            var clearYears: Set<URL> = []

            let browserTargets = metaTargets.filter { CatalogMetaRouting.needsBrowser(for: $0) }
            let httpTargets = metaTargets.filter { !CatalogMetaRouting.needsBrowser(for: $0) }

            // Phase 2 : scraping HTTP / WebKit pour le reste.
            await withTaskGroup(of: (URL, Int?, String?, Bool).self) { group in
                for result in httpTargets {
                    group.addTask { @MainActor in
                        await self.yieldToSelectionEnrichment()
                        let page = CatalogMetaRouting.pageURL(for: result)
                        report(result.sourceSite, result.title, page)
                        guard let html = try? await HTTPClient.fetchString(from: page) else {
                            return (page, nil, nil, false)
                        }
                        let wantsYear = result.releaseYear == nil
                            || CatalogMetaRouting.needsReleaseYearRefresh(result)
                        let year = wantsYear
                            ? ReleaseYearParser.detect(fromHTML: html)
                            : nil
                        let shouldClear = year == nil
                            && result.releaseYear != nil
                            && CatalogMetaRouting.needsReleaseYearRefresh(result)
                        let genre = result.genre == nil
                            ? GenreParser.detect(fromHTML: html)
                            : nil
                        return (page, year, genre, shouldClear)
                    }
                }
                for await (url, year, genre, shouldClear) in group {
                    if let year { years[url] = year }
                    if let genre { genres[url] = genre }
                    if shouldClear { clearYears.insert(url) }
                }
            }

            // RomsFun via WebKit (Cloudflare) — séquentiel, date EU prioritaire.
            // Écrase une année erronée ; sans bloc Release Date fiable → effacement.
            for result in browserTargets {
                guard !Task.isCancelled else { break }
                await yieldToSelectionEnrichment()
                let page = CatalogMetaRouting.pageURL(for: result)
                report("RomsFun", result.title, page)
                guard let html = try? await BrowserHTMLClient.shared.fetchHTML(from: page) else {
                    continue
                }
                if let year = ReleaseYearParser.romsFunReleaseYear(fromHTML: html) {
                    years[page] = year
                } else if CatalogMetaRouting.needsReleaseYearRefresh(result),
                          result.releaseYear != nil {
                    clearYears.insert(page)
                }
                if result.genre == nil,
                   let genre = GenreParser.detect(fromHTML: html) {
                    genres[page] = genre
                }
            }

            guard !Task.isCancelled else {
                isEnriching = false
                liveProgress = nil
                return
            }

            if !years.isEmpty || !genres.isEmpty || !clearYears.isEmpty {
                applyMetaUpdates(years: years, genres: genres, clearYears: clearYears)
            }

            var pendingRH = prioritizeSelected(
                romHustlerSourcesNeedingCover(in: rawResults),
                key: { $0.0.deduplicationKey }
            )
            let waveSize = 80
            while !pendingRH.isEmpty, !Task.isCancelled {
                await yieldToSelectionEnrichment()
                let wave = Array(pendingRH.prefix(waveSize))
                pendingRH = Array(pendingRH.dropFirst(waveSize))
                let coverUpdates = await fetchRomHustlerCovers(wave, report: report)
                guard !Task.isCancelled else { break }
                if !coverUpdates.isEmpty {
                    applyCoverUpdates(coverUpdates)
                }
            }

            var pendingRF = prioritizeSelected(
                romsFunSourcesNeedingCover(in: rawResults),
                key: { $0.0.deduplicationKey }
            )
            pendingRF = Array(pendingRF.prefix(400))
            let romsFunWave = 30
            while !pendingRF.isEmpty, !Task.isCancelled {
                await yieldToSelectionEnrichment()
                let wave = Array(pendingRF.prefix(romsFunWave))
                pendingRF = Array(pendingRF.dropFirst(romsFunWave))
                let coverUpdates = await fetchRomsFunCovers(wave, report: report)
                guard !Task.isCancelled else { break }
                if !coverUpdates.isEmpty {
                    applyCoverUpdates(coverUpdates)
                }
            }

            // Fallback Libretro pour les jeux encore sans jaquette utilisable.
            await enrichTheGamesDBBatch(
                metaCandidates: [],
                includeCoverless: true,
                allowYearCorrection: false,
                report: report,
                coverOnly: true
            )
            await enrichLaunchBoxBatch(
                metaCandidates: [],
                includeCoverless: true,
                allowYearCorrection: false,
                report: report,
                coverOnly: true
            )
            await enrichLibretroCovers(report: report)

            isEnriching = false
            liveProgress = nil
            refreshCatalogSummary()
        }
    }

    /// Date + vignette pour la fiche ouverte (priorité WebKit + pause de l’enrichissement général).
    private func enrichSelectionPriority(_ result: GameResult) async {
        guard !Task.isCancelled else { return }
        let preserveRebuildProgress = isCatalogRebuildRunning
        isSelectionEnriching = true
        defer {
            isSelectionEnriching = false
            if isCatalogRebuildRunning, let backup = catalogRebuildProgressBackup {
                liveProgress = backup
            } else if enrichTask == nil {
                liveProgress = nil
            }
        }

        if !preserveRebuildProgress {
            liveProgress = CatalogLiveProgress(
                phaseLabel: "Fiche sélectionnée…",
                siteName: result.sourceSite,
                urlText: result.title,
                gameTitle: result.title,
                detail: nil,
                activeSites: [],
                discoveredCount: 0
            )
        }

        var current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? result
        let page = CatalogMetaRouting.pageURL(for: current)
        let webPriority: BrowserHTMLClient.FetchPriority = .high

        // TheGamesDB en premier (API).
        _ = await tryTheGamesDBEnrichment(for: current, allowYearCorrection: true)
        current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current

        // LaunchBox Metadata local.
        _ = await tryLaunchBoxEnrichment(for: current, allowYearCorrection: true)
        current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current

        // Année manquante ou correction RomsFun — scraping HTTP ensuite.
        if current.releaseYear == nil || CatalogMetaRouting.needsReleaseYearRefresh(current) {
            if CatalogMetaRouting.needsBrowser(for: current) {
                if let html = try? await BrowserHTMLClient.shared.fetchHTML(from: page, priority: webPriority),
                   let year = ReleaseYearParser.romsFunReleaseYear(fromHTML: html),
                   year != current.releaseYear {
                    applyMetaUpdates(years: [page: year], genres: [:])
                    current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
                } else if current.releaseYear != nil,
                          CatalogMetaRouting.needsReleaseYearRefresh(current) {
                    applyMetaUpdates(years: [:], genres: [:], clearYears: [page])
                    current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
                }
            } else if current.releaseYear == nil
                        || CatalogMetaRouting.needsReleaseYearRefresh(current),
                      let year = await fetchReleaseYear(for: current, webPriority: webPriority) {
                applyMetaUpdates(years: [page: year], genres: [:])
                current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
            } else if current.releaseYear != nil,
                      CatalogMetaRouting.needsReleaseYearRefresh(current) {
                applyMetaUpdates(years: [:], genres: [:], clearYears: [page])
                current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
            }
        }

        guard !Task.isCancelled else { return }

        if !CoverArtParser.isUsableCover(current.thumbnailURL) {
            _ = await tryTheGamesDBEnrichment(for: current, allowYearCorrection: false)
            current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
            _ = await tryLaunchBoxEnrichment(for: current, allowYearCorrection: false)
            current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
        }

        var updates: [URL: URL] = [:]
        for source in current.sources where !CoverArtParser.isUsableCover(source.thumbnailURL) {
            let host = source.pageURL.host?.lowercased() ?? ""
            if host.contains("romhustler.org") {
                guard let html = try? await HTTPClient.fetchString(from: source.pageURL),
                      let cover = CoverArtParser.romHustlerCover(fromHTML: html) else { continue }
                updates[source.pageURL] = cover
            } else if host.contains("romsfun.com") {
                if let fromPreview = await PagePreviewCache.shared.romsFunCoverURL(for: source.pageURL) {
                    updates[source.pageURL] = fromPreview
                    continue
                }
                guard let cover = try? await BrowserHTMLClient.shared.fetchRomsFunCover(
                    from: source.pageURL,
                    priority: webPriority
                ) else {
                    continue
                }
                updates[source.pageURL] = cover
            }
        }

        if !updates.isEmpty {
            applyCoverUpdates(updates)
            current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? current
        }

        guard !Task.isCancelled else { return }

        if !CoverArtParser.isUsableCover(current.thumbnailURL),
           current.platform.libretroSystemFolder != nil,
           let libretro = await LibretroThumbnails.shared.coverURL(
               title: current.title,
               platform: current.platform,
               region: current.region
           ) {
            applyCoverUpdates([current.primarySource.pageURL: libretro])
        }

        if let key = selectedResult?.deduplicationKey,
           let refreshed = rawResults.first(where: { $0.deduplicationKey == key }) {
            selectedResult = refreshed
        }
    }

    /// Laisse l’enrichissement de la fiche ouverte terminer avant la suite du scraping général.
    private func yieldToSelectionEnrichment() async {
        guard !isSelectionEnriching, let task = selectionEnrichTask else { return }
        await task.value
    }

    /// Complète un lot via TheGamesDB avant le scraping HTTP/WebKit.
    private func enrichTheGamesDBBatch(
        metaCandidates: [GameResult],
        includeCoverless: Bool,
        allowYearCorrection: Bool,
        report: @escaping @Sendable (String, String, URL) -> Void,
        coverOnly: Bool = false,
        limit: Int = 80
    ) async {
        guard await TheGamesDBClient.shared.isConfigured else { return }

        var seen = Set<String>()
        var candidates: [GameResult] = []

        if !coverOnly {
            for result in prioritizeSelected(metaCandidates, key: \.deduplicationKey) {
                guard seen.insert(result.deduplicationKey).inserted else { continue }
                candidates.append(result)
            }
        }

        if includeCoverless || coverOnly {
            for result in rawResults where !CoverArtParser.isUsableCover(result.thumbnailURL) {
                guard result.platform.gamesDBPlatformID != nil else { continue }
                guard seen.insert(result.deduplicationKey).inserted else { continue }
                candidates.append(result)
            }
        }

        candidates = prioritizeSelected(Array(candidates.prefix(limit)), key: \.deduplicationKey)

        for result in candidates {
            guard !Task.isCancelled else { break }
            await yieldToSelectionEnrichment()
            _ = await tryTheGamesDBEnrichment(
                for: result,
                report: report,
                allowYearCorrection: allowYearCorrection,
                coverOnly: coverOnly
            )
        }
    }

    /// Une fiche via TheGamesDB (année / genre / vignette).
    @discardableResult
    private func tryTheGamesDBEnrichment(
        for result: GameResult,
        report: ((String, String, URL) -> Void)? = nil,
        allowYearCorrection: Bool = false,
        coverOnly: Bool = false
    ) async -> Bool {
        guard await TheGamesDBClient.shared.isConfigured else { return false }

        let current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? result
        let wantYear = !coverOnly && (
            current.releaseYear == nil
                || (allowYearCorrection && CatalogMetaRouting.needsReleaseYearRefresh(current))
        )
        let wantCover = !CoverArtParser.isUsableCover(current.thumbnailURL)
        let wantGenre = !coverOnly && current.genre == nil
        guard wantYear || wantCover || wantGenre else { return false }

        report?(
            "TheGamesDB",
            current.title,
            URL(string: "https://thegamesdb.net") ?? current.pageURL
        )

        guard let hit = await TheGamesDBClient.shared.lookup(for: current) else { return false }

        let page = CatalogMetaRouting.pageURL(for: current)
        var years: [URL: Int] = [:]
        var genres: [URL: String] = [:]
        var covers: [URL: URL] = [:]

        if wantYear, let year = hit.releaseYear {
            years[page] = year
        }
        if wantGenre, let genre = hit.genre {
            genres[page] = genre
        }
        if wantCover, let cover = hit.coverURL, CoverArtParser.isUsableCover(cover) {
            covers[page] = cover
        }

        guard !years.isEmpty || !genres.isEmpty || !covers.isEmpty else { return false }

        if !years.isEmpty || !genres.isEmpty {
            applyMetaUpdates(years: years, genres: genres)
        }
        if !covers.isEmpty {
            applyCoverUpdates(covers)
        }
        return true
    }

    /// Complète un lot via LaunchBox Metadata (local).
    private func enrichLaunchBoxBatch(
        metaCandidates: [GameResult],
        includeCoverless: Bool,
        allowYearCorrection: Bool,
        report: @escaping @Sendable (String, String, URL) -> Void,
        coverOnly: Bool = false,
        limit: Int = 120
    ) async {
        guard await LaunchBoxMetadataClient.shared.isConfigured else { return }

        var seen = Set<String>()
        var candidates: [GameResult] = []

        if !coverOnly {
            for result in prioritizeSelected(metaCandidates, key: \.deduplicationKey) {
                guard seen.insert(result.deduplicationKey).inserted else { continue }
                candidates.append(result)
            }
        }

        if includeCoverless || coverOnly {
            for result in rawResults where !CoverArtParser.isUsableCover(result.thumbnailURL) {
                guard result.platform.launchBoxPlatformNames.isEmpty == false else { continue }
                guard seen.insert(result.deduplicationKey).inserted else { continue }
                candidates.append(result)
            }
        }

        candidates = prioritizeSelected(Array(candidates.prefix(limit)), key: \.deduplicationKey)

        for result in candidates {
            guard !Task.isCancelled else { break }
            await yieldToSelectionEnrichment()
            _ = await tryLaunchBoxEnrichment(
                for: result,
                report: report,
                allowYearCorrection: allowYearCorrection,
                coverOnly: coverOnly
            )
        }
    }

    /// Une fiche via LaunchBox Metadata local.
    @discardableResult
    private func tryLaunchBoxEnrichment(
        for result: GameResult,
        report: ((String, String, URL) -> Void)? = nil,
        allowYearCorrection: Bool = false,
        coverOnly: Bool = false
    ) async -> Bool {
        guard await LaunchBoxMetadataClient.shared.isConfigured else { return false }

        let current = rawResults.first(where: { $0.deduplicationKey == result.deduplicationKey }) ?? result
        let wantYear = !coverOnly && (
            current.releaseYear == nil
                || (allowYearCorrection && CatalogMetaRouting.needsReleaseYearRefresh(current))
        )
        let wantCover = !CoverArtParser.isUsableCover(current.thumbnailURL)
        let wantGenre = !coverOnly && current.genre == nil
        guard wantYear || wantCover || wantGenre else { return false }

        report?(
            "LaunchBox",
            current.title,
            URL(string: "https://gamesdb.launchbox-app.com") ?? current.pageURL
        )

        guard let hit = await LaunchBoxMetadataClient.shared.lookup(for: current) else { return false }

        let page = CatalogMetaRouting.pageURL(for: current)
        var years: [URL: Int] = [:]
        var genres: [URL: String] = [:]
        var covers: [URL: URL] = [:]

        if wantYear, let year = hit.releaseYear {
            years[page] = year
        }
        if wantGenre, let genre = hit.genre {
            genres[page] = genre
        }
        if wantCover, let cover = hit.coverURL, CoverArtParser.isUsableCover(cover) {
            covers[page] = cover
        }

        guard !years.isEmpty || !genres.isEmpty || !covers.isEmpty else { return false }

        if !years.isEmpty || !genres.isEmpty {
            applyMetaUpdates(years: years, genres: genres)
        }
        if !covers.isEmpty {
            applyCoverUpdates(covers)
        }
        return true
    }

    private func prioritizeSelected<T>(_ items: [T], key: (T) -> String) -> [T] {
        guard let selected = selectedResult else { return items }
        let selectedKey = selected.deduplicationKey
        return items.sorted { a, b in
            let aSel = key(a) == selectedKey
            let bSel = key(b) == selectedKey
            if aSel != bSel { return aSel }
            return false
        }
    }

    /// Remplit les jaquettes manquantes via thumbnails.libretro.com.
    private func enrichLibretroCovers(
        report: @escaping @Sendable (String, String, URL) -> Void
    ) async {
        var pending = prioritizeSelected(
            rawResults.filter {
                !CoverArtParser.isUsableCover($0.thumbnailURL) && $0.platform.libretroSystemFolder != nil
            },
            key: \.deduplicationKey
        )
        pending = Array(pending.prefix(250))
        guard !pending.isEmpty else { return }

        var batch: [URL: URL] = [:]
        for result in pending {
            guard !Task.isCancelled else { break }
            await yieldToSelectionEnrichment()
            let placeholder = URL(string: "https://thumbnails.libretro.com/")!
            report("Libretro", result.title, placeholder)
            guard let cover = await LibretroThumbnails.shared.coverURL(
                title: result.title,
                platform: result.platform,
                region: result.region
            ) else { continue }
            report("Libretro", result.title, cover)
            batch[result.primarySource.pageURL] = cover
            if batch.count >= 40 {
                applyCoverUpdates(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            applyCoverUpdates(batch)
        }
    }

    private func romHustlerSourcesNeedingCover(in results: [GameResult]) -> [(GameResult, GameSource)] {
        results.flatMap { result -> [(GameResult, GameSource)] in
            result.sources
                .filter {
                    !CoverArtParser.isUsableCover($0.thumbnailURL)
                        && $0.pageURL.host?.contains("romhustler.org") == true
                }
                .map { (result, $0) }
        }
    }

    private func romsFunSourcesNeedingCover(in results: [GameResult]) -> [(GameResult, GameSource)] {
        results.flatMap { result -> [(GameResult, GameSource)] in
            result.sources
                .filter {
                    !CoverArtParser.isUsableCover($0.thumbnailURL)
                        && $0.pageURL.host?.contains("romsfun.com") == true
                }
                .map { (result, $0) }
        }
    }

    private func fetchRomHustlerCovers(
        _ targets: [(GameResult, GameSource)],
        report: @escaping @Sendable (String, String, URL) -> Void
    ) async -> [URL: URL] {
        await withTaskGroup(of: (URL, URL?).self) { group in
            var iterator = targets.makeIterator()
            let concurrency = min(8, targets.count)
            for _ in 0 ..< concurrency {
                guard let (result, source) = iterator.next() else { break }
                group.addTask {
                    report("RomHustler", result.title, source.pageURL)
                    guard let html = try? await HTTPClient.fetchString(from: source.pageURL) else {
                        return (source.pageURL, nil)
                    }
                    return (source.pageURL, CoverArtParser.romHustlerCover(fromHTML: html))
                }
            }

            var map: [URL: URL] = [:]
            while let (page, cover) = await group.next() {
                if let cover { map[page] = cover }
                if let (result, source) = iterator.next() {
                    group.addTask {
                        report("RomHustler", result.title, source.pageURL)
                        guard let html = try? await HTTPClient.fetchString(from: source.pageURL) else {
                            return (source.pageURL, nil)
                        }
                        return (source.pageURL, CoverArtParser.romHustlerCover(fromHTML: html))
                    }
                }
            }
            return map
        }
    }

    private func fetchRomsFunCovers(
        _ targets: [(GameResult, GameSource)],
        report: @escaping @Sendable (String, String, URL) -> Void
    ) async -> [URL: URL] {
        var map: [URL: URL] = [:]
        for (result, source) in targets {
            guard !Task.isCancelled else { break }
            report("RomsFun", result.title, source.pageURL)
            guard let cover = try? await BrowserHTMLClient.shared.fetchRomsFunCover(from: source.pageURL) else {
                continue
            }
            map[source.pageURL] = cover
        }
        return map
    }

    private func fetchReleaseYear(
        for result: GameResult,
        webPriority: BrowserHTMLClient.FetchPriority = .normal
    ) async -> Int? {
        let page = CatalogMetaRouting.pageURL(for: result)
        if CatalogMetaRouting.needsBrowser(for: result) {
            guard let html = try? await BrowserHTMLClient.shared.fetchHTML(from: page, priority: webPriority) else {
                return nil
            }
            return ReleaseYearParser.romsFunReleaseYear(fromHTML: html)
        }
        guard let html = try? await HTTPClient.fetchString(from: page) else {
            return nil
        }
        return ReleaseYearParser.detect(fromHTML: html)
    }

    private func applyMetaUpdates(
        years: [URL: Int],
        genres: [URL: String],
        clearYears: Set<URL> = []
    ) {
        rawResults = rawResults.map { result in
            var updated = result
            let matchedPages = [result.pageURL] + result.sources.map(\.pageURL)
            if matchedPages.contains(where: clearYears.contains) {
                updated = updated.withReleaseYear(nil)
            }
            let year = years[result.pageURL]
                ?? result.sources.compactMap { years[$0.pageURL] }.first
            if let year {
                updated = updated.withReleaseYear(year)
            }
            if let genre = genres[result.pageURL]
                ?? result.sources.compactMap({ genres[$0.pageURL] }).first {
                updated = updated.updating(genre: genre)
            }
            return updated
        }
        persistCatalogAndRefreshUI()
    }

    private func applyCoverUpdates(_ coverUpdates: [URL: URL]) {
        rawResults = rawResults.map { result in
            var updated = result
            for source in result.sources {
                if let thumb = coverUpdates[source.pageURL] {
                    updated = updated.updatingThumbnail(thumb, forPageURL: source.pageURL)
                }
            }
            return updated
        }
        persistCatalogAndRefreshUI()
    }

    private func persistCatalogAndRefreshUI() {
        if let platform = selectedPlatform {
            cache.store(
                platform,
                outcome: SearchOutcome(results: rawResults, errors: sourceErrors)
            )
            catalogUpdatedAt = cache.lastUpdated(for: platform)
        }
        applySortAndFilter()
    }
}

private struct IndexedGame: Sendable {
    let index: Int
    let game: GameResult
}

struct CatalogToast: Identifiable, Equatable {
    let id: UUID
    /// Console ou opération concernée (ex. « Game Boy Color », « Vignettes »).
    let listLabel: String
    let message: String
    /// Console à reprendre (bouton dans le toast).
    let resumePlatform: Platform?

    init(id: UUID = UUID(), list: String, message: String, resumePlatform: Platform? = nil) {
        self.id = id
        self.listLabel = list
        self.message = message
        self.resumePlatform = resumePlatform
    }
}

private extension CatalogViewModel {
    var catalogRebuildConcurrency: Int {
        ParallelFetch.concurrency
    }
}
