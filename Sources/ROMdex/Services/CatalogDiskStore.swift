import Foundation

/// Snapshot catalogue persisté sur disque (un fichier JSON par console).
struct CatalogSnapshot: Codable {
    static let currentSchema = 2

    let schemaVersion: Int
    let platform: Platform
    let updatedAt: Date
    let results: [GameResult]
    let errors: [String]

    var outcome: SearchOutcome {
        SearchOutcome(results: results, errors: errors)
    }

    init(platform: Platform, outcome: SearchOutcome, updatedAt: Date = .now) {
        self.schemaVersion = Self.currentSchema
        self.platform = platform
        self.updatedAt = updatedAt
        self.results = outcome.results
        self.errors = outcome.errors
    }
}

/// Persistance JSON légère dans Application Support (hors cache WebKit).
enum CatalogDiskStore {
    private static let folderName = "Catalog"
    private static let appSupportName = "ROMdex"

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(appSupportName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func fileURL(for platform: Platform) -> URL {
        directoryURL.appendingPathComponent("\(platform.rawValue).json", isDirectory: false)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func load(_ platform: Platform) -> CatalogSnapshot? {
        let url = fileURL(for: platform)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
            guard !snapshot.results.isEmpty else { return nil }
            return snapshot
        } catch {
            return nil
        }
    }

    static func save(_ snapshot: CatalogSnapshot) {
        do {
            try ensureDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let url = fileURL(for: snapshot.platform)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            // Échec disque non bloquant.
        }
    }

    static func save(platform: Platform, outcome: SearchOutcome) {
        save(CatalogSnapshot(platform: platform, outcome: outcome))
    }

    static func remove(_ platform: Platform) {
        try? FileManager.default.removeItem(at: fileURL(for: platform))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func lastUpdated(for platform: Platform) -> Date? {
        load(platform)?.updatedAt
    }
}
