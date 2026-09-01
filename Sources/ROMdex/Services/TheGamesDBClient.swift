import AppKit
import Foundation

/// Métadonnées jeux via l’API [TheGamesDB](https://api.thegamesdb.net/) (dates, boxart, genres).
/// Prioritaire sur le scraping HTTP/WebKit quand le module est activé et qu’une clé API est configurée.
actor TheGamesDBClient {
    static let shared = TheGamesDBClient()

    struct LookupResult: Sendable {
        let releaseYear: Int?
        let coverURL: URL?
        let genre: String?
    }

    private let baseURL = URL(string: "https://api.thegamesdb.net")!
    private var memoryCache: [String: LookupResult] = [:]
    private var negativeCache: Set<String> = []
    private var lastRequestAt: Date?

    private init() {}

    var isConfigured: Bool {
        guard AppPreferences.theGamesDBEnabled else { return false }
        guard let key = AppPreferences.theGamesDBAPIKey else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Résout année / vignette / genre pour un jeu catalogue.
    func lookup(for result: GameResult) async -> LookupResult? {
        guard isConfigured,
              let platformID = result.platform.gamesDBPlatformID else {
            return nil
        }

        let searchTitle = Self.searchTitle(from: result.title)
        guard !searchTitle.isEmpty else { return nil }

        let cacheKey = "\(result.platform.rawValue)|\(Self.normalize(searchTitle))"
        if let cached = memoryCache[cacheKey] { return cachedOrNil(cached) }
        if negativeCache.contains(cacheKey) { return nil }
        if let disk = loadDiskCache()[cacheKey] {
            memoryCache[cacheKey] = disk
            return cachedOrNil(disk)
        }

        await throttle()

        guard let apiKey = AppPreferences.theGamesDBAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return nil
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("v1/Games/ByGameName"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "name", value: searchTitle),
            URLQueryItem(name: "filter[platform]", value: String(platformID)),
            URLQueryItem(
                name: "fields",
                value: "players,publishers,genres,overview,rating,platform,release_date,game_title"
            ),
            URLQueryItem(name: "include", value: "boxart,platform,genres"),
        ]

        guard let url = components.url else { return nil }

        do {
            let data = try await HTTPClient.fetchData(from: url, timeout: 25)
            if let parsed = parseResponse(data, searchTitle: searchTitle, platformID: platformID),
               parsed.releaseYear != nil || parsed.coverURL != nil || parsed.genre != nil {
                memoryCache[cacheKey] = parsed
                saveDiskCacheEntry(key: cacheKey, value: parsed)
                return parsed
            }
            negativeCache.insert(cacheKey)
            saveDiskCacheEntry(key: cacheKey, value: LookupResult(releaseYear: nil, coverURL: nil, genre: nil))
            return nil
        } catch {
            return nil
        }
    }

    @MainActor
    static func presentSettingsPanel() {
        let alert = NSAlert()
        alert.messageText = "TheGamesDB API"
        alert.informativeText = """
        Complète dates et vignettes via l’API TheGamesDB (thegamesdb.net). \
        Clé gratuite sur api.thegamesdb.net/key.php.

        Attention : chaque clé API est limitée à 1 000 requêtes par mois (quota mensuel TheGamesDB). \
        ROMdex met en cache les résultats pour limiter la consommation.

        Si le module est désactivé, ROMdex utilise uniquement le scraping habituel.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")

        let accessory = SettingsAccessoryView()
        alert.accessoryView = accessory.view

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let oldEnabled = AppPreferences.theGamesDBEnabled
        let oldKey = AppPreferences.theGamesDBAPIKey

        AppPreferences.theGamesDBEnabled = accessory.enableCheckbox.state == .on
        let trimmed = accessory.apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AppPreferences.theGamesDBAPIKey = trimmed.isEmpty ? nil : trimmed

        if oldEnabled != AppPreferences.theGamesDBEnabled || oldKey != AppPreferences.theGamesDBAPIKey {
            Task { await TheGamesDBClient.shared.clearCaches() }
        }
    }

    @MainActor
    private final class SettingsAccessoryView: NSObject {
        let view: NSView
        let enableCheckbox: NSButton
        let apiKeyField: NSSecureTextField

        override init() {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))

            let checkbox = NSButton(checkboxWithTitle: "Activer TheGamesDB", target: nil, action: nil)
            checkbox.state = AppPreferences.theGamesDBEnabled ? .on : .off
            checkbox.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: "Clé API")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false

            let quotaHint = NSTextField(labelWithString: "Quota gratuit : 1 000 requêtes / mois")
            quotaHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            quotaHint.textColor = .secondaryLabelColor
            quotaHint.translatesAutoresizingMaskIntoConstraints = false

            let field = NSSecureTextField(frame: .zero)
            field.placeholderString = "Coller la clé API"
            field.stringValue = AppPreferences.theGamesDBAPIKey ?? ""
            field.isEnabled = checkbox.state == .on
            field.translatesAutoresizingMaskIntoConstraints = false

            checkbox.target = nil
            checkbox.action = nil

            container.addSubview(checkbox)
            container.addSubview(label)
            container.addSubview(field)
            container.addSubview(quotaHint)

            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                checkbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                checkbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),

                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                label.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 10),

                field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                field.heightAnchor.constraint(equalToConstant: 24),

                quotaHint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                quotaHint.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
                quotaHint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            ])

            self.view = container
            self.enableCheckbox = checkbox
            self.apiKeyField = field
            super.init()

            checkbox.target = self
            checkbox.action = #selector(toggleKeyField(_:))
        }

        @objc private func toggleKeyField(_ sender: NSButton) {
            apiKeyField.isEnabled = sender.state == .on
        }
    }

    func clearCaches() {
        memoryCache.removeAll()
        negativeCache.removeAll()
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    private func cachedOrNil(_ cached: LookupResult) -> LookupResult? {
        if cached.releaseYear != nil || cached.coverURL != nil || cached.genre != nil {
            return cached
        }
        return nil
    }

    // MARK: - Parsing

    private func parseResponse(_ data: Data, searchTitle: String, platformID: Int) -> LookupResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? String)?.lowercased() == "success",
              let dataObj = json["data"] as? [String: Any],
              let games = dataObj["games"] as? [[String: Any]],
              !games.isEmpty else {
            return nil
        }

        guard let game = pickBestGame(games, searchTitle: searchTitle, platformID: platformID) else {
            return nil
        }

        let includes = json["include"] as? [String: Any]
        let gameID = game["id"].map { String(describing: $0) }
        let year = parseReleaseYear(game["release_date"])
        let genre = parseGenre(game: game, includes: includes)
        let cover = parseCoverURL(gameID: gameID, includes: includes)

        return LookupResult(releaseYear: year, coverURL: cover, genre: genre)
    }

    private func pickBestGame(
        _ games: [[String: Any]],
        searchTitle: String,
        platformID: Int
    ) -> [String: Any]? {
        let queryKey = Self.normalize(Self.searchTitle(from: searchTitle))
        guard !queryKey.isEmpty else { return games.first }

        var best: [String: Any]?
        var bestScore = -1

        for game in games {
            if let platformValue = game["platform"] {
                let ids: [Int]
                if let n = platformValue as? Int {
                    ids = [n]
                } else if let s = platformValue as? String, let n = Int(s) {
                    ids = [n]
                } else if let arr = platformValue as? [Any] {
                    ids = arr.compactMap { ($0 as? Int) ?? Int(String(describing: $0)) }
                } else {
                    ids = []
                }
                if !ids.isEmpty, !ids.contains(platformID) { continue }
            }

            let title = (game["game_title"] as? String)
                ?? (game["gameTitle"] as? String)
                ?? ""
            let score = titleMatchScore(query: queryKey, candidate: title)
            if score > bestScore {
                bestScore = score
                best = game
            }
        }

        return bestScore >= 40 ? best : nil
    }

    private func titleMatchScore(query: String, candidate: String) -> Int {
        let candKey = Self.normalize(Self.searchTitle(from: candidate))
        if candKey == query { return 100 }
        if candKey.contains(query) || query.contains(candKey) { return 75 }
        let qTokens = Set(query.split(separator: " ").map(String.init))
        let cTokens = Set(candKey.split(separator: " ").map(String.init))
        guard !qTokens.isEmpty, !cTokens.isEmpty else { return 0 }
        let overlap = qTokens.intersection(cTokens).count
        return Int((Double(overlap) / Double(max(qTokens.count, cTokens.count))) * 60)
    }

    private func parseReleaseYear(_ value: Any?) -> Int? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        if raw.count >= 4, let year = Int(raw.prefix(4)), (1950 ... 2100).contains(year) {
            return year
        }
        return nil
    }

    private func parseGenre(game: [String: Any], includes: [String: Any]?) -> String? {
        guard let includes,
              let genresInclude = includes["genres"] as? [String: Any],
              let genreData = genresInclude["data"] as? [String: Any] else {
            return nil
        }

        let genreIDs: [String]
        if let ids = game["genres"] as? [Any] {
            genreIDs = ids.map { String(describing: $0) }
        } else if let id = game["genres"] {
            genreIDs = [String(describing: id)]
        } else {
            return nil
        }

        for id in genreIDs {
            if let entry = genreData[id] as? [String: Any],
               let name = entry["name"] as? String,
               !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func parseCoverURL(gameID: String?, includes: [String: Any]?) -> URL? {
        guard let gameID,
              let includes,
              let boxart = includes["boxart"] as? [String: Any],
              let baseURLs = boxart["base_url"] as? [String: Any],
              let data = boxart["data"] as? [String: Any],
              let entries = data[gameID] as? [[String: Any]],
              !entries.isEmpty else {
            return nil
        }

        let originalBase = (baseURLs["original"] as? String) ?? (baseURLs["thumb"] as? String)
        guard var base = originalBase else { return nil }
        if !base.hasSuffix("/") { base += "/" }

        let front = entries.first(where: {
            ($0["side"] as? String)?.lowercased() == "front"
        }) ?? entries.first

        guard let filename = front?["filename"] as? String, !filename.isEmpty else { return nil }
        return URL(string: base + filename)
    }

    // MARK: - Cache disque

    private struct DiskEntry: Codable {
        let releaseYear: Int?
        let coverURL: String?
        let genre: String?
    }

    private var cacheFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ROMdex", isDirectory: true)
            .appendingPathComponent("TheGamesDBCache.json")
    }

    private func loadDiskCache() -> [String: LookupResult] {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let raw = try? JSONDecoder().decode([String: DiskEntry].self, from: data) else {
            return [:]
        }
        var map: [String: LookupResult] = [:]
        for (key, entry) in raw {
            map[key] = LookupResult(
                releaseYear: entry.releaseYear,
                coverURL: entry.coverURL.flatMap(URL.init(string:)),
                genre: entry.genre
            )
        }
        return map
    }

    private func saveDiskCacheEntry(key: String, value: LookupResult) {
        var all = (try? Data(contentsOf: cacheFileURL))
            .flatMap { try? JSONDecoder().decode([String: DiskEntry].self, from: $0) } ?? [:]
        all[key] = DiskEntry(
            releaseYear: value.releaseYear,
            coverURL: value.coverURL?.absoluteString,
            genre: value.genre
        )
        let dir = cacheFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    private func throttle() async {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 0.12 {
                try? await Task.sleep(nanoseconds: UInt64((0.12 - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }

    static func searchTitle(from title: String) -> String {
        var s = stripParenGroups(title)
        s = s.replacingOccurrences(of: #"\s*\[[^\]]+\]\s*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ title: String) -> String {
        let lowered = title.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func stripParenGroups(_ title: String) -> String {
        var s = title
        let pattern = #"\s*\([^)]*\)\s*$"#
        while let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s.replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Platform {
    /// Identifiant plateforme TheGamesDB (`filter[platform]`).
    var gamesDBPlatformID: Int? {
        switch self {
        case .gb: return 5
        case .gbc: return 6
        case .gba: return 4914
        case .nds: return 4911
        case .n3ds: return 4912
        case .nes: return 7
        case .snes: return 8
        case .n64: return 4
        case .gameCube: return 2
        case .wii: return 38
        case .wiiU: return 41
        case .switchPlatform: return 4971
        case .ps1: return 9
        case .ps2: return 10
        case .ps3: return 12
        case .psp: return 11
        case .xbox: return 14
        case .x360: return 15
        case .dreamcast: return 23
        case .mame: return 25
        }
    }
}
