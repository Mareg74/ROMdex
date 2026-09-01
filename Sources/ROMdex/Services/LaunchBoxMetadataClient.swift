import AppKit
import Foundation

/// Métadonnées locales extraites de `Metadata.zip` (LaunchBox Games Database).
/// Prioritaire après TheGamesDB, avant le scraping HTTP/WebKit.
actor LaunchBoxMetadataClient {
    static let shared = LaunchBoxMetadataClient()

    struct LookupResult: Sendable {
        let releaseYear: Int?
        let coverURL: URL?
        let genre: String?
    }

    struct IndexSummary: Sendable {
        let totalGames: Int
        let perPlatform: [Platform: Int]
        let builtAt: Date
    }

    private struct IndexedEntry: Codable, Sendable {
        let title: String
        let releaseYear: Int?
        let genre: String?
        let coverPath: String?
    }

    private struct PlatformIndex: Codable {
        var byNormalized: [String: [IndexedEntry]]
        var savedAt: Date
    }

    private var indexes: [Platform: PlatformIndex] = [:]
    private var lastSummary: IndexSummary?
    private var indexBuildTask: Task<IndexSummary, Error>?

    private init() {}

    var isConfigured: Bool {
        guard AppPreferences.launchBoxMetadataEnabled else { return false }
        return metadataXMLURL() != nil
    }

    func statusLine() async -> String {
        if !AppPreferences.launchBoxMetadataEnabled {
            return "Module désactivé"
        }
        guard metadataXMLURL() != nil else {
            return "Metadata.xml introuvable"
        }
        if indexes.isEmpty {
            await loadIndexesFromDisk()
        }
        if let lastSummary {
            let total = lastSummary.totalGames
            return "Index : \(total) jeu(x) · \(formattedDate(lastSummary.builtAt))"
        }
        return "Index non construit — cliquez « Reconstruire l’index »"
    }

    func lookup(for result: GameResult) async -> LookupResult? {
        guard isConfigured else { return nil }
        if indexes[result.platform] == nil {
            await loadIndexesFromDisk()
        }
        guard let index = indexes[result.platform], !index.byNormalized.isEmpty else {
            return nil
        }

        let queryKey = Self.normalize(Self.searchTitle(from: result.title))
        guard !queryKey.isEmpty else { return nil }

        if let exact = index.byNormalized[queryKey]?.first {
            return entryToResult(exact)
        }

        var best: IndexedEntry?
        var bestScore = 0
        for (key, entries) in index.byNormalized {
            let score = titleMatchScore(query: queryKey, candidate: key)
            if score > bestScore, let entry = entries.first {
                bestScore = score
                best = entry
            }
        }

        guard bestScore >= 40, let best else { return nil }
        return entryToResult(best)
    }

    func rebuildIndex() async throws -> IndexSummary {
        if let inflight = indexBuildTask {
            return try await inflight.value
        }

        guard let metadataURL = metadataXMLURL() else {
            throw LaunchBoxError.metadataNotFound
        }

        let task = Task<IndexSummary, Error> {
            try await self.buildIndex(metadataURL: metadataURL)
        }
        indexBuildTask = task
        defer { indexBuildTask = nil }

        let summary = try await task.value
        lastSummary = summary
        return summary
    }

    func invalidateMemoryIndex() {
        indexes.removeAll()
        lastSummary = nil
    }

    @MainActor
    static func presentSettingsPanel() {
        let alert = NSAlert()
        alert.messageText = "LaunchBox Metadata"
        alert.informativeText = """
        Import local du dump LaunchBox (Metadata.zip). \
        Téléchargez l’archive sur gamesdb.launchbox-app.com/Metadata.zip, \
        extrayez-la, puis sélectionnez le dossier contenant Metadata.xml.

        Aucune requête réseau n’est nécessaire après indexation. \
        Si le module est désactivé, ROMdex ignore cette source.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")

        let accessory = SettingsAccessoryView()
        alert.accessoryView = accessory.view

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let oldEnabled = AppPreferences.launchBoxMetadataEnabled
        let oldPath = AppPreferences.launchBoxMetadataPath

        AppPreferences.launchBoxMetadataEnabled = accessory.enableCheckbox.state == .on
        if let chosen = accessory.selectedPath {
            AppPreferences.launchBoxMetadataPath = chosen.path
        }

        if oldEnabled != AppPreferences.launchBoxMetadataEnabled || oldPath != AppPreferences.launchBoxMetadataPath {
            Task {
                await LaunchBoxMetadataClient.shared.invalidateMemoryIndex()
            }
        }

        if accessory.rebuildRequested {
            Task { @MainActor in
                do {
                    let summary = try await LaunchBoxMetadataClient.shared.rebuildIndex()
                    CatalogTransferNotifier.shared.announce(
                        "Index LaunchBox : \(summary.totalGames) jeu(x) indexé(s)."
                    )
                } catch {
                    CatalogTransferNotifier.shared.announce(
                        "Échec index LaunchBox : \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    // MARK: - Index build

    private func buildIndex(metadataURL: URL) async throws -> IndexSummary {
        let imagesMap = try parseImagesMap(near: metadataURL)
        let parser = MetadataXMLParser(
            allowedPlatforms: Platform.launchBoxPlatformLookup,
            imagesByDatabaseID: imagesMap
        )

        guard let stream = InputStream(url: metadataURL) else {
            throw LaunchBoxError.metadataNotFound
        }
        let xml = XMLParser(stream: stream)
        xml.delegate = parser
        guard xml.parse() else {
            throw LaunchBoxError.parseFailed(xml.parserError?.localizedDescription ?? "XML invalide")
        }

        var perPlatform: [Platform: Int] = [:]
        var indexes: [Platform: PlatformIndex] = [:]
        let now = Date()

        for (platform, entries) in parser.entriesByPlatform {
            var byNormalized: [String: [IndexedEntry]] = [:]
            for entry in entries {
                let indexed = IndexedEntry(
                    title: entry.title,
                    releaseYear: entry.releaseYear,
                    genre: entry.genre,
                    coverPath: entry.coverPath
                )
                let key = Self.normalize(Self.searchTitle(from: entry.title))
                guard !key.isEmpty else { continue }
                byNormalized[key, default: []].append(indexed)
            }
            indexes[platform] = PlatformIndex(byNormalized: byNormalized, savedAt: now)
            perPlatform[platform] = entries.count
            try savePlatformIndex(platform, index: indexes[platform]!)
        }

        self.indexes = indexes
        let total = perPlatform.values.reduce(0, +)
        let summary = IndexSummary(totalGames: total, perPlatform: perPlatform, builtAt: now)
        saveSummary(summary)
        return summary
    }

    private func parseImagesMap(near metadataURL: URL) throws -> [String: String] {
        guard let imagesXML = resolveImagesXML(near: metadataURL) else { return [:] }
        let parser = ImagesXMLParser()
        guard let stream = InputStream(url: imagesXML) else { return [:] }
        let xml = XMLParser(stream: stream)
        xml.delegate = parser
        guard xml.parse() else { return [:] }
        return parser.bestFrontImageByDatabaseID
    }

    private func entryToResult(_ entry: IndexedEntry) -> LookupResult {
        let coverURL = entry.coverPath.flatMap { URL(fileURLWithPath: $0) }
        return LookupResult(releaseYear: entry.releaseYear, coverURL: coverURL, genre: entry.genre)
    }

    // MARK: - Paths

    private func metadataRootURL() -> URL? {
        guard let path = AppPreferences.launchBoxMetadataPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func metadataXMLURL() -> URL? {
        guard let root = metadataRootURL() else { return nil }
        return Self.findMetadataXML(in: root)
    }

    static func findMetadataXML(in root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent("Metadata.xml")
        if fm.fileExists(atPath: direct.path) { return direct }
        let nested = root.appendingPathComponent("Metadata/Metadata.xml")
        if fm.fileExists(atPath: nested.path) { return nested }
        return nil
    }

    private func resolveImagesXML(near metadataURL: URL) -> URL? {
        let fm = FileManager.default
        let parent = metadataURL.deletingLastPathComponent()
        let candidates = [
            parent.appendingPathComponent("Images.xml"),
            parent.deletingLastPathComponent().appendingPathComponent("Images.xml"),
            metadataRootURL()?.appendingPathComponent("Images.xml"),
        ].compactMap { $0 }

        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    func resolveImagesDirectory() -> URL? {
        guard let root = metadataRootURL() else { return nil }
        let fm = FileManager.default
        let candidates = [
            root.appendingPathComponent("Images"),
            root.appendingPathComponent("Metadata/Images"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Disk index

    private var indexDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ROMdex", isDirectory: true)
            .appendingPathComponent("LaunchBoxIndex", isDirectory: true)
    }

    private func platformIndexURL(_ platform: Platform) -> URL {
        indexDirectory.appendingPathComponent("\(platform.rawValue).json")
    }

    private func summaryURL() -> URL {
        indexDirectory.appendingPathComponent("summary.json")
    }

    private func loadIndexesFromDisk() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexDirectory.path) else { return }
        for platform in Platform.allCases {
            let url = platformIndexURL(platform)
            guard let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode(PlatformIndex.self, from: data) else {
                continue
            }
            indexes[platform] = index
        }
        if let data = try? Data(contentsOf: summaryURL()),
           let summary = try? JSONDecoder().decode(StoredSummary.self, from: data) {
            lastSummary = IndexSummary(
                totalGames: summary.totalGames,
                perPlatform: summary.perPlatform.compactMapKeys { Platform(rawValue: $0) },
                builtAt: summary.builtAt
            )
        }
    }

    private struct StoredSummary: Codable {
        let totalGames: Int
        let perPlatform: [String: Int]
        let builtAt: Date
    }

    private func savePlatformIndex(_ platform: Platform, index: PlatformIndex) throws {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(index)
        try data.write(to: platformIndexURL(platform), options: .atomic)
    }

    private func saveSummary(_ summary: IndexSummary) {
        let stored = StoredSummary(
            totalGames: summary.totalGames,
            perPlatform: Dictionary(uniqueKeysWithValues: summary.perPlatform.map { ($0.key.rawValue, $0.value) }),
            builtAt: summary.builtAt
        )
        try? FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: summaryURL(), options: .atomic)
        }
    }

    // MARK: - Matching

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

    private func titleMatchScore(query: String, candidate: String) -> Int {
        if candidate == query { return 100 }
        if candidate.contains(query) || query.contains(candidate) { return 75 }
        let qTokens = Set(query.split(separator: " ").map(String.init))
        let cTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !qTokens.isEmpty, !cTokens.isEmpty else { return 0 }
        let overlap = qTokens.intersection(cTokens).count
        return Int((Double(overlap) / Double(max(qTokens.count, cTokens.count))) * 60)
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    enum LaunchBoxError: LocalizedError {
        case metadataNotFound
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .metadataNotFound:
                return "Metadata.xml introuvable dans le dossier sélectionné."
            case .parseFailed(let msg):
                return "Lecture XML échouée : \(msg)"
            }
        }
    }
}

// MARK: - XML parsers

private final class MetadataXMLParser: NSObject, XMLParserDelegate {
    private struct MutableGame {
        var databaseID: String?
        var name: String?
        var platform: String?
        var releaseYear: Int?
        var releaseDate: String?
        var genres: String?
    }

    struct ParsedEntry {
        let title: String
        let releaseYear: Int?
        let genre: String?
        let coverPath: String?
    }

    let allowedPlatforms: [String: Platform]
    let imagesByDatabaseID: [String: String]
    let imagesDirectory: URL?

    private(set) var entriesByPlatform: [Platform: [ParsedEntry]] = [:]
    private var current: MutableGame?
    private var currentElement = ""

    init(allowedPlatforms: [String: Platform], imagesByDatabaseID: [String: String]) {
        self.allowedPlatforms = allowedPlatforms
        self.imagesByDatabaseID = imagesByDatabaseID
        if let path = AppPreferences.launchBoxMetadataPath {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let fm = FileManager.default
            self.imagesDirectory = [
                root.appendingPathComponent("Images"),
                root.appendingPathComponent("Metadata/Images"),
            ].first { fm.fileExists(atPath: $0.path) }
        } else {
            self.imagesDirectory = nil
        }
        super.init()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Game" {
            current = MutableGame()
            if let id = attributeDict["DatabaseID"] ?? attributeDict["databaseID"] {
                current?.databaseID = id
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var game = current else { return }
        switch currentElement {
        case "DatabaseID": game.databaseID = (game.databaseID ?? "") + string
        case "Name": game.name = (game.name ?? "") + string
        case "Platform": game.platform = (game.platform ?? "") + string
        case "ReleaseYear": game.releaseYear = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case "ReleaseDate": game.releaseDate = (game.releaseDate ?? "") + string
        case "Genres": game.genres = (game.genres ?? "") + string
        default: break
        }
        current = game
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "Game", let game = current else { return }
        current = nil

        guard let platformName = game.platform?.trimmingCharacters(in: .whitespacesAndNewlines),
              let platform = allowedPlatforms[platformName],
              let title = game.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return
        }

        let year = game.releaseYear ?? parseYear(from: game.releaseDate)
        let genre = game.genres?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let dbID = game.databaseID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var coverPath: String?
        if let dbID, let fileName = imagesByDatabaseID[dbID], let imagesDirectory {
            let fileURL = imagesDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                coverPath = fileURL.path
            }
        }

        let entry = ParsedEntry(
            title: title,
            releaseYear: year,
            genre: genre?.isEmpty == false ? genre : nil,
            coverPath: coverPath
        )
        entriesByPlatform[platform, default: []].append(entry)
    }

    private func parseYear(from releaseDate: String?) -> Int? {
        guard let raw = releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 4 else {
            return nil
        }
        return Int(raw.prefix(4))
    }
}

private final class ImagesXMLParser: NSObject, XMLParserDelegate {
    private struct MutableImage {
        var databaseID: String?
        var fileName: String?
        var type: String?
        var region: String?
    }

    private(set) var bestFrontImageByDatabaseID: [String: String] = [:]
    private var scoresByDatabaseID: [String: Int] = [:]
    private var current: MutableImage?
    private var currentElement = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Image" {
            current = MutableImage()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var image = current else { return }
        switch currentElement {
        case "DatabaseID": image.databaseID = (image.databaseID ?? "") + string
        case "FileName": image.fileName = (image.fileName ?? "") + string
        case "Type": image.type = (image.type ?? "") + string
        case "Region": image.region = (image.region ?? "") + string
        default: break
        }
        current = image
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "Image", let image = current else { return }
        current = nil

        guard let dbID = image.databaseID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let fileName = image.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dbID.isEmpty, !fileName.isEmpty else {
            return
        }

        let type = image.type ?? ""
        guard type.localizedCaseInsensitiveContains("box") && type.localizedCaseInsensitiveContains("front") else {
            return
        }

        let score = regionScore(image.region)
        let previous = scoresByDatabaseID[dbID] ?? -1
        if score >= previous {
            scoresByDatabaseID[dbID] = score
            bestFrontImageByDatabaseID[dbID] = fileName
        }
    }

    private func regionScore(_ region: String?) -> Int {
        switch region?.lowercased() ?? "" {
        case "world": return 4
        case "north america": return 3
        case "europe": return 2
        case "japan": return 1
        default: return 0
        }
    }
}

// MARK: - Settings UI

extension LaunchBoxMetadataClient {
    @MainActor
    final class SettingsAccessoryView: NSObject {
        let view: NSView
        let enableCheckbox: NSButton
        let pathField: NSTextField
        let rebuildButton: NSButton
        private(set) var selectedPath: URL?
        private(set) var rebuildRequested = false

        override init() {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 118))

            let checkbox = NSButton(checkboxWithTitle: "Activer LaunchBox Metadata", target: nil, action: nil)
            checkbox.state = AppPreferences.launchBoxMetadataEnabled ? .on : .off
            checkbox.translatesAutoresizingMaskIntoConstraints = false

            let pathLabel = NSTextField(labelWithString: "Dossier Metadata")
            pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            pathLabel.textColor = .secondaryLabelColor
            pathLabel.translatesAutoresizingMaskIntoConstraints = false

            let path = NSTextField(frame: .zero)
            path.isEditable = false
            path.isBordered = true
            path.backgroundColor = .controlBackgroundColor
            path.lineBreakMode = .byTruncatingMiddle
            path.stringValue = AppPreferences.launchBoxMetadataPath ?? "Aucun dossier sélectionné"
            path.translatesAutoresizingMaskIntoConstraints = false

            let choose = NSButton(title: "Choisir…", target: nil, action: nil)
            choose.bezelStyle = .rounded
            choose.translatesAutoresizingMaskIntoConstraints = false

            let rebuild = NSButton(title: "Reconstruire l’index", target: nil, action: nil)
            rebuild.bezelStyle = .rounded
            rebuild.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(checkbox)
            container.addSubview(pathLabel)
            container.addSubview(path)
            container.addSubview(choose)
            container.addSubview(rebuild)

            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                checkbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

                pathLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                pathLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 10),

                path.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                path.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 4),
                path.heightAnchor.constraint(equalToConstant: 22),
                choose.leadingAnchor.constraint(equalTo: path.trailingAnchor, constant: 8),
                choose.centerYAnchor.constraint(equalTo: path.centerYAnchor),
                choose.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                path.trailingAnchor.constraint(equalTo: choose.leadingAnchor, constant: -8),

                rebuild.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                rebuild.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 10),
            ])

            self.view = container
            self.enableCheckbox = checkbox
            self.pathField = path
            self.rebuildButton = rebuild
            self.selectedPath = AppPreferences.launchBoxMetadataPath.map { URL(fileURLWithPath: $0) }
            super.init()

            choose.target = self
            choose.action = #selector(chooseFolder(_:))
            rebuild.target = self
            rebuild.action = #selector(rebuildIndex(_:))
            checkbox.target = self
            checkbox.action = #selector(toggleEnabled(_:))
            toggleEnabled(checkbox)
        }

        @objc private func chooseFolder(_ sender: NSButton) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Sélectionner"
            panel.message = "Choisissez le dossier extrait de Metadata.zip (contenant Metadata.xml)."
            if panel.runModal() == .OK, let url = panel.url {
                selectedPath = url
                pathField.stringValue = url.path
            }
        }

        @objc private func rebuildIndex(_ sender: NSButton) {
            rebuildRequested = true
        }

        @objc private func toggleEnabled(_ sender: NSButton) {
            let enabled = sender.state == .on
            pathField.isEnabled = enabled
        }
    }
}

private extension Dictionary {
    func compactMapKeys<T>(_ transform: (Key) throws -> T?) rethrows -> [T: Value] {
        var result: [T: Value] = [:]
        for (key, value) in self {
            if let newKey = try transform(key) {
                result[newKey] = value
            }
        }
        return result
    }
}

extension Platform {
    /// Noms plateforme dans Metadata.xml LaunchBox.
    static let launchBoxPlatformLookup: [String: Platform] = {
        var map: [String: Platform] = [:]
        for platform in Platform.allCases {
            for name in platform.launchBoxPlatformNames {
                map[name] = platform
            }
        }
        return map
    }()

    var launchBoxPlatformNames: [String] {
        switch self {
        case .gb: return ["Nintendo Game Boy"]
        case .gbc: return ["Nintendo Game Boy Color"]
        case .gba: return ["Nintendo Game Boy Advance"]
        case .nds: return ["Nintendo DS"]
        case .n3ds: return ["Nintendo 3DS"]
        case .nes: return ["Nintendo Entertainment System"]
        case .snes: return ["Super Nintendo Entertainment System"]
        case .n64: return ["Nintendo 64"]
        case .gameCube: return ["Nintendo GameCube"]
        case .wii: return ["Nintendo Wii"]
        case .wiiU: return ["Wii U"]
        case .switchPlatform: return ["Nintendo Switch"]
        case .ps1: return ["Sony PlayStation", "PlayStation"]
        case .ps2: return ["Sony PlayStation 2", "PlayStation 2"]
        case .ps3: return ["Sony Playstation 3", "PlayStation 3", "Sony PlayStation 3"]
        case .psp: return ["Sony PlayStation Portable"]
        case .xbox: return ["Microsoft Xbox"]
        case .x360: return ["Microsoft Xbox 360"]
        case .dreamcast: return ["Sega Dreamcast"]
        case .mame: return ["MAME", "Arcade"]
        }
    }
}
