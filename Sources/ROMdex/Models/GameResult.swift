import Foundation

struct GameSource: Identifiable, Hashable, Codable {
    let id: UUID
    let siteName: String
    let pageURL: URL
    let thumbnailURL: URL?
    let region: GameRegion

    init(
        id: UUID = UUID(),
        siteName: String,
        pageURL: URL,
        thumbnailURL: URL? = nil,
        region: GameRegion
    ) {
        self.id = id
        self.siteName = siteName
        self.pageURL = pageURL
        self.thumbnailURL = thumbnailURL
        self.region = region
    }
}

struct GameResult: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let platform: Platform
    let region: GameRegion
    let releaseYear: Int?
    let genre: String?
    let sources: [GameSource]

    /// Source principale (aperçu / liste).
    var primarySource: GameSource {
        Self.preferredSource(among: sources)
    }

    var sourceSite: String { primarySource.siteName }
    var pageURL: URL { primarySource.pageURL }
    var thumbnailURL: URL? {
        sources.compactMap(\.thumbnailURL).first { CoverArtParser.isUsableCover($0) }
    }

    var sourceCount: Int { sources.count }

    var availableRegions: [GameRegion] {
        var seen = Set<GameRegion>()
        var ordered: [GameRegion] = []
        for source in sources {
            if seen.insert(source.region).inserted {
                ordered.append(source.region)
            }
        }
        return ordered
    }

    var sourceNamesSummary: String {
        let names = sources.map(\.siteName)
        if names.count <= 2 {
            return names.joined(separator: " · ")
        }
        return "\(names[0]) · +\(names.count - 1)"
    }

    init(
        id: UUID = UUID(),
        title: String,
        platform: Platform,
        region: GameRegion? = nil,
        sourceSite: String,
        pageURL: URL,
        thumbnailURL: URL? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil,
        regionHint: String? = nil
    ) {
        let resolvedRegion = region ?? GameRegion.detect(fromTitle: title, hint: regionHint)
        self.init(
            id: id,
            title: title,
            platform: platform,
            region: resolvedRegion,
            releaseYear: releaseYear
                ?? ReleaseYearParser.detect(from: title)
                ?? ReleaseYearParser.detect(from: pageURL.absoluteString)
                ?? (regionHint.flatMap { ReleaseYearParser.detect(from: $0) }),
            genre: genre,
            sources: [
                GameSource(
                    siteName: sourceSite,
                    pageURL: pageURL,
                    thumbnailURL: thumbnailURL,
                    region: resolvedRegion
                )
            ]
        )
    }

    init(
        id: UUID = UUID(),
        title: String,
        platform: Platform,
        region: GameRegion,
        releaseYear: Int?,
        genre: String? = nil,
        sources: [GameSource]
    ) {
        precondition(!sources.isEmpty, "GameResult requires at least one source")
        let deduped = Self.dedupeSources(sources)
        self.id = id
        self.title = title
        self.platform = platform
        self.sources = deduped
        self.releaseYear = releaseYear
        self.genre = genre
        self.region = Self.preferredSource(among: deduped).region
    }

    /// Fusion titre + plateforme uniquement (les régions restent sur chaque source).
    var deduplicationKey: String {
        let normalizedTitle = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedTitle)|\(platform.rawValue)"
    }

    func merging(with other: GameResult) -> GameResult {
        let mergedSources = Self.dedupeSources(sources + other.sources)
        return GameResult(
            id: id,
            title: preferredTitle(with: other),
            platform: platform,
            region: Self.preferredSource(among: mergedSources).region,
            releaseYear: releaseYear ?? other.releaseYear,
            genre: genre ?? other.genre,
            sources: mergedSources
        )
    }

    /// Conserve année / genre / jaquettes déjà enrichis quand on fusionne un re-scrape.
    func mergingPreservingEnrichment(with scraped: GameResult) -> GameResult {
        let mergedSources = Self.dedupeSources(sources + scraped.sources)
        return GameResult(
            id: id,
            title: preferredTitle(with: scraped),
            platform: platform,
            region: Self.preferredSource(among: mergedSources).region,
            releaseYear: releaseYear ?? scraped.releaseYear,
            genre: genre ?? scraped.genre,
            sources: mergedSources
        )
    }

    private func preferredTitle(with other: GameResult) -> String {
        // Titre plus « propre » (moins de tags dump) si l’autre est plus long / sans [!].
        let a = title
        let b = other.title
        let aTagged = a.contains("[") || a.contains("(")
        let bTagged = b.contains("[") || b.contains("(")
        if aTagged && !bTagged { return b }
        if bTagged && !aTagged { return a }
        return a.count >= b.count ? a : b
    }

    /// Ne conserve que les sources des régions demandées (filtre UI).
    func restrictingSources(to regions: Set<GameRegion>) -> GameResult? {
        guard !regions.isEmpty else { return self }
        let matching = sources.filter { regions.contains($0.region) }
        guard !matching.isEmpty else { return nil }
        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: matching[0].region,
            releaseYear: releaseYear,
            genre: genre,
            sources: matching
        )
    }

    /// Ne conserve que les sources dont le site n’est pas masqué (filtre UI).
    /// `hiddenSiteNames` vide = toutes les sources visibles.
    func restrictingSources(hidingSiteNames hiddenSiteNames: Set<String>) -> GameResult? {
        guard !hiddenSiteNames.isEmpty else { return self }
        let matching = sources.filter { !hiddenSiteNames.contains($0.siteName) }
        guard !matching.isEmpty else { return nil }
        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: Self.preferredSource(among: matching).region,
            releaseYear: releaseYear,
            genre: genre,
            sources: matching
        )
    }

    /// Ne conserve que les sources dont la région n’est pas masquée (filtre UI catalogue).
    func restrictingSources(hidingRegions hiddenRegions: Set<GameRegion>) -> GameResult? {
        guard !hiddenRegions.isEmpty else { return self }
        let matching = sources.filter { !hiddenRegions.contains($0.region) }
        guard !matching.isEmpty else { return nil }
        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: Self.preferredSource(among: matching).region,
            releaseYear: releaseYear,
            genre: genre,
            sources: matching
        )
    }

    /// Régions uniques présentes dans une liste de jeux (ordre canonique).
    static func availableRegions(in results: [GameResult]) -> [GameRegion] {
        var seen = Set<GameRegion>()
        for result in results {
            for source in result.sources {
                seen.insert(source.region)
            }
        }
        return GameRegion.allCases.filter { seen.contains($0) }
    }

    /// Noms de sites uniques présents dans une liste de jeux (triés).
    static func availableSourceSiteNames(in results: [GameResult]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for result in results {
            for source in result.sources {
                if seen.insert(source.siteName).inserted {
                    ordered.append(source.siteName)
                }
            }
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Remplace l’année de sortie, y compris par `nil` (effacement explicite).
    func withReleaseYear(_ releaseYear: Int?) -> GameResult {
        GameResult(
            id: id,
            title: title,
            platform: platform,
            region: Self.preferredSource(among: sources).region,
            releaseYear: releaseYear,
            genre: genre,
            sources: sources
        )
    }

    func updating(
        region: GameRegion? = nil,
        thumbnailURL: URL? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil
    ) -> GameResult {
        var newSources = sources
        if let thumbnailURL {
            if let index = newSources.firstIndex(where: { $0.thumbnailURL == nil }) {
                let old = newSources[index]
                newSources[index] = GameSource(
                    id: old.id,
                    siteName: old.siteName,
                    pageURL: old.pageURL,
                    thumbnailURL: thumbnailURL,
                    region: region ?? old.region
                )
            } else if let first = newSources.first {
                newSources[0] = GameSource(
                    id: first.id,
                    siteName: first.siteName,
                    pageURL: first.pageURL,
                    thumbnailURL: thumbnailURL,
                    region: region ?? first.region
                )
            }
        } else if let region {
            newSources = newSources.map { old in
                GameSource(
                    id: old.id,
                    siteName: old.siteName,
                    pageURL: old.pageURL,
                    thumbnailURL: old.thumbnailURL,
                    region: region
                )
            }
        }

        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: region ?? Self.preferredSource(among: newSources).region,
            releaseYear: releaseYear ?? self.releaseYear,
            genre: genre ?? self.genre,
            sources: newSources
        )
    }

    func updatingThumbnail(_ thumbnailURL: URL, forPageURL pageURL: URL) -> GameResult {
        guard CoverArtParser.isUsableCover(thumbnailURL) else { return self }
        let newSources = sources.map { source in
            guard source.pageURL == pageURL else { return source }
            return GameSource(
                id: source.id,
                siteName: source.siteName,
                pageURL: source.pageURL,
                thumbnailURL: thumbnailURL,
                region: source.region
            )
        }
        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: region,
            releaseYear: releaseYear,
            genre: genre,
            sources: newSources
        )
    }

    /// Retire les placeholders console (ex. `xbox-360-console-of-games.png`) des sources.
    func strippingJunkThumbnails() -> GameResult {
        var changed = false
        let cleaned = sources.map { source -> GameSource in
            guard let thumb = source.thumbnailURL, CoverArtParser.isLikelyJunkCover(thumb) else {
                return source
            }
            changed = true
            return GameSource(
                id: source.id,
                siteName: source.siteName,
                pageURL: source.pageURL,
                thumbnailURL: nil,
                region: source.region
            )
        }
        guard changed else { return self }
        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: region,
            releaseYear: releaseYear,
            genre: genre,
            sources: cleaned
        )
    }

    func updatingRegion(_ region: GameRegion, forPageURL pageURL: URL) -> GameResult {
        let newSources = sources.map { source in
            guard source.pageURL == pageURL else { return source }
            return GameSource(
                id: source.id,
                siteName: source.siteName,
                pageURL: source.pageURL,
                thumbnailURL: source.thumbnailURL,
                region: region
            )
        }
        return GameResult(
            id: id,
            title: title,
            platform: platform,
            region: Self.preferredSource(among: newSources).region,
            releaseYear: releaseYear,
            genre: genre,
            sources: newSources
        )
    }

    static func preferredSource(among sources: [GameSource]) -> GameSource {
        if let romspedia = sources.first(where: {
            $0.siteName == "Romspedia" && CoverArtParser.isUsableCover($0.thumbnailURL)
        }) {
            return romspedia
        }
        if let withThumb = sources.first(where: { CoverArtParser.isUsableCover($0.thumbnailURL) }) {
            return withThumb
        }
        return sources[0]
    }

    private static func dedupeSources(_ sources: [GameSource]) -> [GameSource] {
        var byKey: [String: GameSource] = [:]
        for source in sources {
            let key = "\(source.siteName.lowercased())|\(source.pageURL.absoluteString)"
            if let existing = byKey[key] {
                byKey[key] = preferEnrichedSource(existing, source)
            } else {
                byKey[key] = source
            }
        }
        return Array(byKey.values).sorted {
            if $0.region.displayName != $1.region.displayName {
                return $0.region.displayName < $1.region.displayName
            }
            if ($0.thumbnailURL != nil) != ($1.thumbnailURL != nil) {
                return $0.thumbnailURL != nil
            }
            if ($0.siteName == "Romspedia") != ($1.siteName == "Romspedia") {
                return $0.siteName == "Romspedia"
            }
            return $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending
        }
    }

    private static func preferEnrichedSource(_ a: GameSource, _ b: GameSource) -> GameSource {
        switch (a.thumbnailURL, b.thumbnailURL) {
        case (.some, .none):
            return a
        case (.none, .some):
            return b
        default:
            if a.region != .other && b.region == .other { return a }
            if b.region != .other && a.region == .other { return b }
            return a
        }
    }
}

enum ResultMerger {
    static func merge(_ results: [GameResult]) -> [GameResult] {
        var byKey: [String: GameResult] = [:]

        for result in results {
            let key = result.deduplicationKey
            if let existing = byKey[key] {
                byKey[key] = existing.merging(with: result)
            } else {
                byKey[key] = result
            }
        }

        return Array(byKey.values)
    }
}

/// Fusion catalogue : conserve jaquettes / année / genre déjà OK, ajoute les nouveaux jeux.
enum CatalogMerger {
    static func mergePreservingEnrichment(previous: [GameResult], scraped: [GameResult]) -> [GameResult] {
        guard !previous.isEmpty else { return scraped }
        guard !scraped.isEmpty else { return previous }

        var byKey: [String: GameResult] = [:]
        for old in previous {
            byKey[old.deduplicationKey] = old
        }
        for fresh in scraped {
            let key = fresh.deduplicationKey
            if let existing = byKey[key] {
                byKey[key] = existing.mergingPreservingEnrichment(with: fresh)
            } else {
                byKey[key] = fresh
            }
        }
        return Array(byKey.values)
    }
}

enum CatalogSortOrder: String, CaseIterable, Identifiable {
    case titleAsc
    case titleDesc
    case yearAsc
    case yearDesc
    case region
    case source

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .titleAsc: return "Titre A → Z"
        case .titleDesc: return "Titre Z → A"
        case .yearAsc: return "Année (ancien → récent)"
        case .yearDesc: return "Année (récent → ancien)"
        case .region: return "Région"
        case .source: return "Nombre de sources"
        }
    }

    func sorted(_ results: [GameResult]) -> [GameResult] {
        switch self {
        case .titleAsc:
            return results.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .titleDesc:
            return results.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
            }
        case .yearAsc:
            return results.sorted { lhs, rhs in
                switch (lhs.releaseYear, rhs.releaseYear) {
                case let (l?, r?):
                    if l != r { return l < r }
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .yearDesc:
            return results.sorted { lhs, rhs in
                switch (lhs.releaseYear, rhs.releaseYear) {
                case let (l?, r?):
                    if l != r { return l > r }
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .region:
            return results.sorted {
                let l = $0.availableRegions.map(\.displayName).joined()
                let r = $1.availableRegions.map(\.displayName).joined()
                if l != r { return l < r }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .source:
            return results.sorted {
                if $0.sourceCount != $1.sourceCount {
                    return $0.sourceCount > $1.sourceCount
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }
}
