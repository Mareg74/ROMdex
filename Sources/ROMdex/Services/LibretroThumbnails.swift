import Foundation

/// Jaquettes de secours depuis https://thumbnails.libretro.com
/// (`{System}/Named_Boxarts/{Game}.png`, puis `Named_Titles`).
actor LibretroThumbnails {
    static let shared = LibretroThumbnails()

    private let baseURL = URL(string: "https://thumbnails.libretro.com")!
    private var indexes: [Platform: SystemIndex] = [:]
    private var loading: [Platform: Task<SystemIndex?, Never>] = [:]

    private struct SystemIndex {
        /// Nom de fichier complet → clé normalisée (sans groupes entre parenthèses).
        let byNormalized: [String: [String]]
        let systemFolder: String
        let kinds: [String]
    }

    /// Résout une URL de jaquette Libretro, ou `nil` si introuvable.
    func coverURL(
        title: String,
        platform: Platform,
        region: GameRegion? = nil
    ) async -> URL? {
        guard let system = platform.libretroSystemFolder else { return nil }
        guard let index = await index(for: platform, systemFolder: system) else { return nil }

        let queryKey = Self.normalize(Self.stripParenGroups(title))
        guard !queryKey.isEmpty else { return nil }

        let filenames = bestFilenames(queryKey: queryKey, in: index, region: region)
        for name in filenames {
            for kind in index.kinds {
                if let url = makeURL(system: index.systemFolder, kind: kind, fileName: name) {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - Index

    private func index(for platform: Platform, systemFolder: String) async -> SystemIndex? {
        if let cached = indexes[platform] { return cached }
        if let inflight = loading[platform] {
            return await inflight.value
        }

        let task = Task<SystemIndex?, Never> {
            await self.buildIndex(platform: platform, systemFolder: systemFolder)
        }
        loading[platform] = task
        let built = await task.value
        loading[platform] = nil
        if let built {
            indexes[platform] = built
        }
        return built
    }

    private func buildIndex(platform: Platform, systemFolder: String) async -> SystemIndex? {
        if let disk = loadDiskIndex(platform: platform), !disk.byNormalized.isEmpty {
            return disk
        }

        var byNormalized: [String: [String]] = [:]
        var kindsFound: [String] = []

        for kind in ["Named_Boxarts", "Named_Titles"] {
            guard let names = await fetchListing(system: systemFolder, kind: kind), !names.isEmpty else {
                continue
            }
            kindsFound.append(kind)
            for name in names {
                let base = Self.stripParenGroups(Self.stripExtension(name))
                let key = Self.normalize(base)
                guard !key.isEmpty else { continue }
                byNormalized[key, default: []].append(name)
            }
        }

        guard !byNormalized.isEmpty else { return nil }

        let index = SystemIndex(
            byNormalized: byNormalized,
            systemFolder: systemFolder,
            kinds: kindsFound.isEmpty ? ["Named_Boxarts"] : kindsFound
        )
        saveDiskIndex(platform: platform, index: index)
        return index
    }

    private func fetchListing(system: String, kind: String) async -> [String]? {
        guard let url = directoryURL(system: system, kind: kind) else { return nil }
        guard let html = try? await HTTPClient.fetchString(from: url, timeout: 45) else {
            return nil
        }

        // Apache autoindex : href="Game%20Name%20(USA).png"
        let pattern = #"href="([^"?]+\.png)""#
        var names: [String] = []
        names.reserveCapacity(2_048)
        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let raw = match.groups[0]
            guard !raw.hasPrefix("?"), !raw.hasPrefix("/") else { continue }
            let decoded = raw.removingPercentEncoding ?? raw
            guard decoded.lowercased().hasSuffix(".png") else { continue }
            names.append(decoded)
        }
        return names
    }

    // MARK: - Match

    private func bestFilenames(
        queryKey: String,
        in index: SystemIndex,
        region: GameRegion?
    ) -> [String] {
        var candidates = index.byNormalized[queryKey] ?? []

        if candidates.isEmpty {
            // Préfixe / containment pour titres partiels (ex. dump tags restants).
            let fuzzy = index.byNormalized.compactMap { key, files -> (String, [String])? in
                if key == queryKey { return (key, files) }
                if key.hasPrefix(queryKey), queryKey.count >= 4 { return (key, files) }
                if queryKey.hasPrefix(key), key.count >= 6 { return (key, files) }
                return nil
            }
            // Préférer la clé la plus proche en longueur.
            if let best = fuzzy.min(by: {
                abs($0.0.count - queryKey.count) < abs($1.0.count - queryKey.count)
            }) {
                candidates = best.1
            }
        }

        guard !candidates.isEmpty else { return [] }

        return candidates.sorted { a, b in
            score(fileName: a, region: region) > score(fileName: b, region: region)
        }
    }

    private func score(fileName: String, region: GameRegion?) -> Int {
        let lower = fileName.lowercased()
        var value = 0
        if lower.contains("(world)") { value += 3 }
        if lower.contains("(usa, europe)") || lower.contains("(usa,europe)") { value += 3 }
        if lower.contains("(europe)") { value += 2 }
        if lower.contains("(usa)") { value += 2 }
        if lower.contains("(japan)") { value += 1 }

        switch region {
        case .eu, .france:
            if lower.contains("europe") || lower.contains("(fr)") || lower.contains("(de)")
                || lower.contains("(es)") || lower.contains("(it)") || lower.contains("(en)")
                || lower.contains("(france)") {
                value += 10
            }
        case .us:
            if lower.contains("(usa)") { value += 10 }
        case .ja:
            if lower.contains("(japan)") || lower.contains("(jp)") { value += 10 }
        case .other, .none:
            break
        }
        return value
    }

    // MARK: - URLs

    private func directoryURL(system: String, kind: String) -> URL? {
        var url = baseURL
        url.appendPathComponent(system)
        url.appendPathComponent(kind)
        url.appendPathComponent("") // trailing slash for directory listing
        return url
    }

    private func makeURL(system: String, kind: String, fileName: String) -> URL? {
        var url = baseURL
        url.appendPathComponent(system)
        url.appendPathComponent(kind)
        url.appendPathComponent(fileName)
        return url
    }

    // MARK: - Normalize

    static func stripExtension(_ name: String) -> String {
        if name.lowercased().hasSuffix(".png") {
            return String(name.dropLast(4))
        }
        return name
    }

    /// Retire les groupes `(USA)`, `(Rev A)`, etc. en fin de nom.
    static func stripParenGroups(_ title: String) -> String {
        var s = title
        let pattern = #"\s*\([^)]*\)\s*$"#
        while let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Tags dump fréquents.
        s = s.replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
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

    // MARK: - Disk cache

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ROMdex", isDirectory: true)
            .appendingPathComponent("LibretroIndex", isDirectory: true)
    }

    private func diskURL(for platform: Platform) -> URL {
        cacheDirectory.appendingPathComponent("\(platform.rawValue).json")
    }

    private struct DiskPayload: Codable {
        let systemFolder: String
        let kinds: [String]
        let byNormalized: [String: [String]]
        let savedAt: Date
    }

    private func loadDiskIndex(platform: Platform) -> SystemIndex? {
        let url = diskURL(for: platform)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) else {
            return nil
        }
        // Rafraîchir au-delà de 30 jours.
        if payload.savedAt.addingTimeInterval(60 * 60 * 24 * 30) < Date() {
            return nil
        }
        return SystemIndex(
            byNormalized: payload.byNormalized,
            systemFolder: payload.systemFolder,
            kinds: payload.kinds
        )
    }

    private func saveDiskIndex(platform: Platform, index: SystemIndex) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let payload = DiskPayload(
            systemFolder: index.systemFolder,
            kinds: index.kinds,
            byNormalized: index.byNormalized,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: diskURL(for: platform), options: .atomic)
    }
}

extension Platform {
    /// Dossier système sur thumbnails.libretro.com (`nil` = non couvert).
    var libretroSystemFolder: String? {
        switch self {
        case .gb: return "Nintendo - Game Boy"
        case .gbc: return "Nintendo - Game Boy Color"
        case .gba: return "Nintendo - Game Boy Advance"
        case .nds: return "Nintendo - Nintendo DS"
        case .n3ds: return "Nintendo - Nintendo 3DS"
        case .nes: return "Nintendo - Nintendo Entertainment System"
        case .snes: return "Nintendo - Super Nintendo Entertainment System"
        case .n64: return "Nintendo - Nintendo 64"
        case .gameCube: return "Nintendo - GameCube"
        case .wii: return "Nintendo - Wii"
        case .wiiU: return "Nintendo - Wii U"
        case .switchPlatform: return nil // Pas de dossier Switch sur le CDN
        case .ps1: return "Sony - PlayStation"
        case .ps2: return "Sony - PlayStation 2"
        case .ps3: return "Sony - PlayStation 3"
        case .psp: return "Sony - PlayStation Portable"
        case .xbox: return "Microsoft - Xbox"
        case .x360: return "Microsoft - Xbox 360"
        case .dreamcast: return "Sega - Dreamcast"
        case .mame: return "MAME"
        }
    }
}
