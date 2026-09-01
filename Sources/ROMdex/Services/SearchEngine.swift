import Foundation

struct SearchEngine {
    let adapters: [any SiteAdapter]

    init(adapters: [any SiteAdapter] = [
        VimmAdapter(),
        RetrosticAdapter(),
        CDRomanceAdapter(),
        MondemulAdapter(),
        RomspediaAdapter(),
        RomHustlerAdapter(),
        RomUlationAdapter(),
        CoolROMAdapter(),
        RomsPureAdapter(),
        DLPSGameAdapter(),
        NSWGameAdapter(),
        DLXBGameAdapter(),
        DownloadGamePSPAdapter(),
        DopeROMSAdapter(),
        RomsManiaAdapter(),
        GamulatorAdapter(),
        ROMDepotAdapter(),
        LostROMsAdapter(),
        ROMNationAdapter(),
        TheOldComputerAdapter(),
        Xbox360ISOAdapter(),
        InternetArchiveAdapter(),
        NXBrewAdapter(),
        RomsFunAdapter()
    ]) {
        self.adapters = adapters
    }

    func search(query: String, platforms: Set<Platform>) async -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchOutcome(results: [], errors: [])
        }

        // Aucune plateforme = toutes ; sinon une recherche par plateforme sélectionnée.
        let platformTargets: [Platform?] = platforms.isEmpty
            ? [nil]
            : platforms.map { Optional($0) }

        let jobs: [SearchJob] = platformTargets.flatMap { platform in
            adapters.map { SearchJob(adapter: $0, platform: platform) }
        }

        let concurrency = AppPreferences.fetchParallelEnabled
            ? min(jobs.count, max(12, AppPreferences.fetchConcurrencyPerHost * 3))
            : 1

        let results = await ParallelFetch.map(jobs, concurrency: concurrency) { job in
            await self.runAdapter(job.adapter, query: trimmed, platform: job.platform)
        }

        let merged = deduplicate(results.flatMap(\.results))
        let errors = ScrapeErrorFilter.filterStoredErrors(
            Array(Set(results.compactMap(\.errorMessage))).sorted()
        )
        return SearchOutcome(results: merged, errors: errors)
    }

    private func runAdapter(_ adapter: any SiteAdapter, query: String, platform: Platform?) async -> AdapterOutcome {
        do {
            let results = try await adapter.search(query: query, platform: platform)
            return AdapterOutcome(source: adapter.displayName, results: results, errorMessage: nil)
        } catch let error as SiteAdapterError {
            return AdapterOutcome(
                source: adapter.displayName,
                results: [],
                errorMessage: "\(adapter.displayName): \(error.localizedDescription)"
            )
        } catch {
            guard let message = ScrapeErrorFilter.formatBrowseError(
                adapterName: adapter.displayName,
                error: error
            ) else {
                return AdapterOutcome(source: adapter.displayName, results: [], errorMessage: nil)
            }
            return AdapterOutcome(source: adapter.displayName, results: [], errorMessage: message)
        }
    }

    private func deduplicate(_ results: [GameResult]) -> [GameResult] {
        ResultMerger.merge(results).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

struct SearchOutcome {
    let results: [GameResult]
    let errors: [String]
}

private struct AdapterOutcome {
    let source: String
    let results: [GameResult]
    let errorMessage: String?
}

private struct SearchJob: Sendable {
    let adapter: any SiteAdapter
    let platform: Platform?
}
