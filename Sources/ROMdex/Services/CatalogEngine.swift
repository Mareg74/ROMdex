import Foundation

struct CatalogEngine {
    /// Sources avec un vrai listing console (fusion multi-sites).
    let adapters: [any SiteAdapter]

    var adapterIds: [String] {
        adapters.map(\.id)
    }

    init(adapters: [any SiteAdapter] = [
        VimmAdapter(),
        RetrosticAdapter(),
        CDRomanceAdapter(),
        RomspediaAdapter(),
        RomHustlerAdapter(),
        RomUlationAdapter(),
        RomsPureAdapter(),
        CoolROMAdapter(),
        DLPSGameAdapter(),
        NSWGameAdapter(),
        DLXBGameAdapter(),
        DownloadGamePSPAdapter(),
        RomsManiaAdapter(),
        GamulatorAdapter(),
        Xbox360ISOAdapter(),
        InternetArchiveAdapter(),
        TheOldComputerAdapter(),
        NXBrewAdapter(),
        RomsFunAdapter()
    ]) {
        self.adapters = adapters
    }

    func browse(
        platform: Platform,
        skipAdapterIds: Set<String> = [],
        onProgress: (@Sendable (CatalogProgressEvent, [String]) -> Void)? = nil,
        onPartial: (@Sendable (CatalogBrowseResponse) -> Void)? = nil
    ) async -> CatalogBrowseResponse {
        let hub = onProgress.map { CatalogBrowseProgress.Hub(emit: $0) }
        let pending = adapters.filter { !skipAdapterIds.contains($0.id) }
        let totalCount = adapters.count

        return await CatalogBrowseProgress.$hub.withValue(hub) {
            guard !pending.isEmpty else {
                let empty = makeBrowseResponse(
                    outcomes: [],
                    skipAdapterIds: skipAdapterIds,
                    totalCount: totalCount
                )
                onPartial?(empty)
                return empty
            }

            let concurrency = AppPreferences.fetchParallelEnabled ? pending.count : 1
            return await runBrowseAdapters(
                pending,
                platform: platform,
                skipAdapterIds: skipAdapterIds,
                totalCount: totalCount,
                concurrency: concurrency,
                onPartial: onPartial
            )
        }
    }

    /// Parallélisme annulable : retourne les sources déjà terminées sans attendre les requêtes en vol.
    private func runBrowseAdapters(
        _ pending: [any SiteAdapter],
        platform: Platform,
        skipAdapterIds: Set<String>,
        totalCount: Int,
        concurrency: Int,
        onPartial: (@Sendable (CatalogBrowseResponse) -> Void)?
    ) async -> CatalogBrowseResponse {
        if concurrency <= 1 {
            var outcomes: [AdapterBrowseOutcome] = []
            outcomes.reserveCapacity(pending.count)
            for adapter in pending {
                if Task.isCancelled { break }
                let outcome = await runBrowse(adapter, platform: platform)
                outcomes.append(outcome)
                onPartial?(makeBrowseResponse(
                    outcomes: outcomes,
                    skipAdapterIds: skipAdapterIds,
                    totalCount: totalCount
                ))
            }
            return makeBrowseResponse(
                outcomes: outcomes,
                skipAdapterIds: skipAdapterIds,
                totalCount: totalCount
            )
        }

        var slots: [AdapterBrowseOutcome?] = Array(repeating: nil, count: pending.count)

        return await withTaskGroup(of: (Int, AdapterBrowseOutcome).self) { group in
            var nextIndex = 0
            var inFlight = 0
            let limit = max(1, concurrency)

            func schedule() {
                while inFlight < limit, nextIndex < pending.count {
                    let index = nextIndex
                    nextIndex += 1
                    inFlight += 1
                    let adapter = pending[index]
                    group.addTask {
                        let outcome = await self.runBrowse(adapter, platform: platform)
                        return (index, outcome)
                    }
                }
            }

            func emitPartial() {
                let outcomes = slots.compactMap { $0 }
                onPartial?(makeBrowseResponse(
                    outcomes: outcomes,
                    skipAdapterIds: skipAdapterIds,
                    totalCount: totalCount
                ))
            }

            schedule()

            while inFlight > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                guard let (index, outcome) = await group.next() else { break }
                slots[index] = outcome
                inFlight -= 1
                emitPartial()
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                schedule()
            }

            return makeBrowseResponse(
                outcomes: slots.compactMap { $0 },
                skipAdapterIds: skipAdapterIds,
                totalCount: totalCount
            )
        }
    }

    private func makeBrowseResponse(
        outcomes: [AdapterBrowseOutcome],
        skipAdapterIds: Set<String>,
        totalCount: Int
    ) -> CatalogBrowseResponse {
        var completedIds = skipAdapterIds
        for outcome in outcomes where outcome.completed {
            completedIds.insert(outcome.adapterId)
        }
        let merged = deduplicate(outcomes.flatMap(\.results))
        let errors = ScrapeErrorFilter.filterStoredErrors(
            Array(Set(outcomes.compactMap(\.errorMessage))).sorted()
        )
        return CatalogBrowseResponse(
            outcome: SearchOutcome(results: merged, errors: errors),
            completedAdapterIds: Array(completedIds),
            totalAdapterCount: totalCount
        )
    }

    private func runBrowse(_ adapter: any SiteAdapter, platform: Platform) async -> AdapterBrowseOutcome {
        if Task.isCancelled {
            return AdapterBrowseOutcome(
                adapterId: adapter.id,
                completed: false,
                results: [],
                errorMessage: nil
            )
        }
        let hub = CatalogBrowseProgress.hub
        hub?.started(adapter.displayName)

        return await CatalogBrowseProgress.$siteName.withValue(adapter.displayName) {
            do {
                let results = try await adapter.browse(platform: platform)
                hub?.finished(adapter.displayName, count: results.count)
                if results.isEmpty {
                    return AdapterBrowseOutcome(
                        adapterId: adapter.id,
                        completed: true,
                        results: [],
                        errorMessage: nil
                    )
                }
                return AdapterBrowseOutcome(
                    adapterId: adapter.id,
                    completed: true,
                    results: results,
                    errorMessage: nil
                )
            } catch let error as SiteAdapterError {
                switch error {
                case .unsupportedPlatform:
                    hub?.finished(adapter.displayName, count: 0)
                    return AdapterBrowseOutcome(
                        adapterId: adapter.id,
                        completed: true,
                        results: [],
                        errorMessage: nil
                    )
                default:
                    hub?.failed(adapter.displayName, message: error.localizedDescription)
                    return AdapterBrowseOutcome(
                        adapterId: adapter.id,
                        completed: true,
                        results: [],
                        errorMessage: "\(adapter.displayName): \(error.localizedDescription)"
                    )
                }
            } catch {
                if ScrapeErrorFilter.isCancellation(error) {
                    hub?.failed(adapter.displayName, message: "Interrompu")
                    return AdapterBrowseOutcome(
                        adapterId: adapter.id,
                        completed: false,
                        results: [],
                        errorMessage: nil
                    )
                }
                if let message = ScrapeErrorFilter.formatBrowseError(
                    adapterName: adapter.displayName,
                    error: error
                ) {
                    hub?.failed(adapter.displayName, message: message)
                    return AdapterBrowseOutcome(
                        adapterId: adapter.id,
                        completed: true,
                        results: [],
                        errorMessage: message
                    )
                }
                hub?.finished(adapter.displayName, count: 0)
                return AdapterBrowseOutcome(
                    adapterId: adapter.id,
                    completed: true,
                    results: [],
                    errorMessage: nil
                )
            }
        }
    }

    private func deduplicate(_ results: [GameResult]) -> [GameResult] {
        ResultMerger.merge(results)
    }
}

struct CatalogBrowseResponse: Sendable {
    let outcome: SearchOutcome
    let completedAdapterIds: [String]
    let totalAdapterCount: Int
}

private struct AdapterBrowseOutcome {
    let adapterId: String
    let completed: Bool
    let results: [GameResult]
    let errorMessage: String?
}

/// Cache mémoire LRU (peu de consoles) + miroir disque JSON.
@MainActor
final class CatalogCache {
    static let shared = CatalogCache()

    private let maxMemoryPlatforms = 3
    private var storage: [Platform: SearchOutcome] = [:]
    private var order: [Platform] = []
    private var updatedAt: [Platform: Date] = [:]

    func lookup(_ platform: Platform) -> SearchOutcome? {
        if let mem = storage[platform], !mem.results.isEmpty {
            touch(platform)
            return mem
        }

        guard let snapshot = CatalogDiskStore.load(platform) else { return nil }
        storeInMemory(platform, outcome: snapshot.outcome, date: snapshot.updatedAt)
        return snapshot.outcome
    }

    func lastUpdated(for platform: Platform) -> Date? {
        if let date = updatedAt[platform] { return date }
        return CatalogDiskStore.lastUpdated(for: platform)
    }

    func store(_ platform: Platform, outcome: SearchOutcome, persist: Bool = true) {
        let date = Date()
        storeInMemory(platform, outcome: outcome, date: date)
        if persist {
            CatalogDiskStore.save(platform: platform, outcome: outcome)
        }
        CatalogLocalSearch.invalidate()
    }

    /// Invalide mémoire + disque pour forcer un re-scrape.
    func remove(_ platform: Platform) {
        storage.removeValue(forKey: platform)
        updatedAt.removeValue(forKey: platform)
        order.removeAll { $0 == platform }
        CatalogDiskStore.remove(platform)
        CatalogLocalSearch.invalidate()
    }

    /// Vide seulement la RAM (les JSON restent).
    func clearMemory() {
        storage.removeAll()
        order.removeAll()
        updatedAt.removeAll()
    }

    /// Vide RAM + fichiers catalogue.
    func clear() {
        clearMemory()
        CatalogDiskStore.clear()
        CatalogLocalSearch.invalidate()
    }

    private func storeInMemory(_ platform: Platform, outcome: SearchOutcome, date: Date) {
        storage[platform] = outcome
        updatedAt[platform] = date
        touch(platform)
        while order.count > maxMemoryPlatforms {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
            updatedAt.removeValue(forKey: evicted)
        }
    }

    private func touch(_ platform: Platform) {
        order.removeAll { $0 == platform }
        order.append(platform)
    }
}

/// Index mémoire des catalogues scrapés — évite de relire le disque à chaque frappe.
final class CatalogLocalSearchIndex: @unchecked Sendable {
    static let shared = CatalogLocalSearchIndex()

    private struct Entry {
        let platform: Platform
        let titleLower: String
        let game: GameResult
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var isLoaded = false
    private var generation = 0

    func invalidate() {
        lock.lock()
        entries = []
        isLoaded = false
        generation += 1
        lock.unlock()
    }

    /// Précharge en arrière-plan (appelé au démarrage / 1ʳᵉ recherche).
    func warmup() {
        _ = snapshotEntries()
    }

    func search(query: String, platforms: Set<Platform>) -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let all = snapshotEntries()
        let filterPlatforms = !platforms.isEmpty

        var matches: [GameResult] = []
        matches.reserveCapacity(min(128, all.count))

        for entry in all {
            if filterPlatforms, !platforms.contains(entry.platform) { continue }
            if tokens.allSatisfy({ entry.titleLower.contains($0) }) {
                matches.append(entry.game)
            }
        }

        return ResultMerger.merge(matches).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func snapshotEntries() -> [Entry] {
        lock.lock()
        if isLoaded {
            let copy = entries
            lock.unlock()
            return copy
        }
        let gen = generation
        lock.unlock()

        var built: [Entry] = []
        built.reserveCapacity(8_192)
        for platform in Platform.allCases {
            guard let games = CatalogDiskStore.load(platform)?.results else { continue }
            for game in games {
                built.append(Entry(platform: platform, titleLower: game.title.lowercased(), game: game))
            }
        }

        lock.lock()
        if generation == gen {
            entries = built
            isLoaded = true
        }
        let copy = isLoaded && generation == gen ? entries : built
        lock.unlock()
        return copy
    }
}

enum CatalogLocalSearch {
    static func search(query: String, platforms: Set<Platform>) -> [GameResult] {
        CatalogLocalSearchIndex.shared.search(query: query, platforms: platforms)
    }

    static func invalidate() {
        CatalogLocalSearchIndex.shared.invalidate()
    }

    static func warmup() {
        CatalogLocalSearchIndex.shared.warmup()
    }
}
