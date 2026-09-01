import CryptoKit
import Foundation

/// Empreintes listing (page 1) pour détecter un changement de catalogue sans scrape complet.
struct CatalogFingerprintState: Codable {
    var fingerprints: [String: String] = [:]
    var flaggedPlatforms: [String] = []
    var lastCheckAt: Date?

    mutating func flag(_ platform: Platform) {
        let key = platform.rawValue
        if !flaggedPlatforms.contains(key) {
            flaggedPlatforms.append(key)
        }
    }

    mutating func clearFlag(_ platform: Platform) {
        flaggedPlatforms.removeAll { $0 == platform.rawValue }
    }

    func isFlagged(_ platform: Platform) -> Bool {
        flaggedPlatforms.contains(platform.rawValue)
    }

    static func storageKey(platform: Platform, sourceID: String) -> String {
        "\(platform.rawValue)|\(sourceID)"
    }
}

enum CatalogFingerprintStore {
    private static let fileName = "catalog-fingerprints.json"

    private static var fileURL: URL {
        CatalogDiskStore.directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> CatalogFingerprintState {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CatalogFingerprintState.self, from: data) else {
            return CatalogFingerprintState()
        }
        return state
    }

    static func save(_ state: CatalogFingerprintState) {
        do {
            try CatalogDiskStore.ensureDirectory()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            let url = fileURL
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            // Non bloquant.
        }
    }
}

enum CatalogFingerprint {
    static func digest(_ tokens: [String]) -> String {
        let payload = tokens.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Liens `/rom/{slug}/…` triés (RomHustler).
    static func fromRomHustlerHTML(_ html: String) -> String? {
        let paths = HTMLParser.matches(
            in: html,
            pattern: #"href="(?:https://romhustler\.org)?(/rom/[a-z0-9-]+/[^"?#]+)"#
        ).map(\.groups[0])
        guard !paths.isEmpty else { return nil }
        return digest(Array(Set(paths)))
    }

    /// Liens `/roms/{slug}/…` Romspedia (hors pagination).
    static func fromRomspediaHTML(_ html: String, slug: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: slug)
        let pattern = "href=\"(/roms/" + escaped + "/[^\"?#]+)\""
        let paths = HTMLParser.matches(in: html, pattern: pattern)
            .map(\.groups[0])
            .filter { path in
                !path.contains("?") && path != "/roms/\(slug)" && !path.hasSuffix("/roms/\(slug)/")
            }
        guard !paths.isEmpty else { return nil }
        return digest(Array(Set(paths)))
    }

    /// Compteur Popular + liens fiches RomsFun.
    static func fromRomsFunHTML(_ html: String, slug: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: slug)
        var tokens: [String] = []

        if let count = HTMLParser.matches(
            in: html,
            pattern: #"Popular ROMs\s*\((\d+)\)"#
        ).first?.groups.first {
            tokens.append("popular:\(count)")
        }

        let pathPattern = "href=\"(?:https://romsfun\\.com)?(/roms/" + escaped + "/[a-z0-9][a-z0-9-]*\\.html)\""
        let paths = HTMLParser.matches(in: html, pattern: pathPattern).map(\.groups[0])
        tokens.append(contentsOf: Set(paths))

        guard !tokens.isEmpty else { return nil }
        return digest(tokens)
    }
}
