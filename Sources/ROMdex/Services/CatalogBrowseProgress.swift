import Foundation

/// Événement de scrape catalogue (affiché sous le spinner).
struct CatalogProgressEvent: Sendable, Equatable {
    var siteName: String
    var url: URL?
    var gameTitle: String?
    var detail: String?
    var phase: Phase
    /// Compteur cumulé de jeux découverts pour ce scrape.
    var discoveredCount: Int

    enum Phase: String, Sendable, Equatable {
        case started
        case fetching
        case game
        case finished
        case failed
        case enriching
    }

    init(
        siteName: String,
        url: URL? = nil,
        gameTitle: String? = nil,
        detail: String? = nil,
        phase: Phase,
        discoveredCount: Int = 0
    ) {
        self.siteName = siteName
        self.url = url
        self.gameTitle = gameTitle
        self.detail = detail
        self.phase = phase
        self.discoveredCount = discoveredCount
    }
}

/// État agrégé pour l’UI.
struct CatalogLiveProgress: Equatable {
    var phaseLabel: String
    var siteName: String?
    var urlText: String?
    var gameTitle: String?
    var detail: String?
    var activeSites: [String]
    /// Total jeux découverts depuis le début du scrape (toutes sources).
    var discoveredCount: Int
    /// Avancement optionnel (ex. reconstruction dates : 45/891).
    var progressIndex: Int?
    var progressTotal: Int?

    static func from(event: CatalogProgressEvent, activeSites: [String]) -> CatalogLiveProgress {
        let phaseLabel: String
        switch event.phase {
        case .started: phaseLabel = "Connexion…"
        case .fetching: phaseLabel = "Téléchargement…"
        case .game: phaseLabel = "Analyse…"
        case .finished: phaseLabel = "Terminé"
        case .failed: phaseLabel = "Échec"
        case .enriching: phaseLabel = "Enrichissement…"
        }

        return CatalogLiveProgress(
            phaseLabel: phaseLabel,
            siteName: event.siteName,
            urlText: event.url?.absoluteString,
            gameTitle: event.gameTitle,
            detail: event.detail,
            activeSites: activeSites,
            discoveredCount: event.discoveredCount
        )
    }
}

/// Progression thread-safe via `@TaskLocal` (HTTP + adapters).
enum CatalogBrowseProgress {
    @TaskLocal static var hub: Hub?

    final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var active: Set<String> = []
        private var gamesFound = 0
        private let emit: @Sendable (CatalogProgressEvent, [String]) -> Void

        init(emit: @escaping @Sendable (CatalogProgressEvent, [String]) -> Void) {
            self.emit = emit
        }

        var discoveredCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return gamesFound
        }

        func started(_ site: String) {
            lock.lock()
            active.insert(site)
            let sites = Array(active).sorted()
            let total = gamesFound
            lock.unlock()
            emit(
                CatalogProgressEvent(
                    siteName: site,
                    url: nil,
                    gameTitle: nil,
                    detail: nil,
                    phase: .started,
                    discoveredCount: total
                ),
                sites
            )
        }

        func finished(_ site: String, count: Int) {
            lock.lock()
            active.remove(site)
            // Ne pas ré-additionner `count` : déjà cumulé via `reportGames` / `recordGames`.
            let sites = Array(active).sorted()
            let total = gamesFound
            lock.unlock()
            emit(
                CatalogProgressEvent(
                    siteName: site,
                    url: nil,
                    gameTitle: nil,
                    detail: "\(count) jeu(x)",
                    phase: .finished,
                    discoveredCount: total
                ),
                sites
            )
        }

        func failed(_ site: String, message: String) {
            lock.lock()
            active.remove(site)
            let sites = Array(active).sorted()
            let total = gamesFound
            lock.unlock()
            emit(
                CatalogProgressEvent(
                    siteName: site,
                    url: nil,
                    gameTitle: nil,
                    detail: message,
                    phase: .failed,
                    discoveredCount: total
                ),
                sites
            )
        }

        func fetching(url: URL) {
            let site = CatalogBrowseProgress.siteName ?? snapshotActive().last ?? "Source"
            emit(
                CatalogProgressEvent(
                    siteName: site,
                    url: url,
                    gameTitle: nil,
                    detail: nil,
                    phase: .fetching,
                    discoveredCount: discoveredCount
                ),
                snapshotActive()
            )
        }

        func game(site: String, title: String, url: URL?) {
            emit(
                CatalogProgressEvent(
                    siteName: site,
                    url: url,
                    gameTitle: title,
                    detail: nil,
                    phase: .game,
                    discoveredCount: discoveredCount
                ),
                snapshotActive()
            )
        }

        func recordGames(_ count: Int) {
            guard count > 0 else { return }
            lock.lock()
            gamesFound += count
            let total = gamesFound
            let sites = Array(active).sorted()
            let site = CatalogBrowseProgress.siteName ?? sites.last ?? "Source"
            lock.unlock()
            emit(
                CatalogProgressEvent(
                    siteName: site,
                    url: nil,
                    gameTitle: nil,
                    detail: nil,
                    phase: .game,
                    discoveredCount: total
                ),
                sites
            )
        }

        func enriching(title: String, url: URL) {
            emit(
                CatalogProgressEvent(
                    siteName: "Pages détail",
                    url: url,
                    gameTitle: title,
                    detail: nil,
                    phase: .enriching,
                    discoveredCount: discoveredCount
                ),
                snapshotActive()
            )
        }

        private func snapshotActive() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(active).sorted()
        }
    }

    @TaskLocal static var siteName: String?

    static func reportFetching(_ url: URL) {
        hub?.fetching(url: url)
    }

    static func reportGame(site: String, title: String, url: URL?) {
        hub?.game(site: site, title: title, url: url)
    }

    static func reportGames(site: String, _ games: [GameResult]) {
        guard let hub else { return }
        hub.recordGames(games.count)
        // Échantillonne pour ne pas saturer l’UI sur les très gros lots.
        let stride = max(1, games.count / 40)
        for (index, game) in games.enumerated() where index % stride == 0 {
            hub.game(site: site, title: game.title, url: game.pageURL)
        }
        if let last = games.last {
            hub.game(site: site, title: last.title, url: last.pageURL)
        }
    }

    static func reportEnriching(title: String, url: URL) {
        hub?.enriching(title: title, url: url)
    }
}
