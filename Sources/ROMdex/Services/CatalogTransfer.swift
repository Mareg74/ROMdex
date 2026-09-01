import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export / import du catalogue complet (ZIP de JSON `CatalogSnapshot`).
enum CatalogTransfer {
    static let exportUTI = UTType.zip
    static let manifestFileName = "manifest.json"
    static let coversFolderName = "Covers"
    static let appID = "ROMdex"

    struct Manifest: Codable {
        let app: String
        let schemaVersion: Int
        let exportedAt: Date
        let platforms: [String]
        let includeFingerprints: Bool
        let includeCovers: Bool

        init(
            app: String,
            schemaVersion: Int,
            exportedAt: Date,
            platforms: [String],
            includeFingerprints: Bool,
            includeCovers: Bool = false
        ) {
            self.app = app
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.platforms = platforms
            self.includeFingerprints = includeFingerprints
            self.includeCovers = includeCovers
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = try c.decode(String.self, forKey: .app)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            exportedAt = try c.decode(Date.self, forKey: .exportedAt)
            platforms = try c.decode([String].self, forKey: .platforms)
            includeFingerprints = try c.decode(Bool.self, forKey: .includeFingerprints)
            includeCovers = try c.decodeIfPresent(Bool.self, forKey: .includeCovers) ?? false
        }
    }

    enum ImportMode {
        case replace
        case merge
    }

    struct ImportSummary {
        var platformsImported: Int = 0
        var gamesAdded: Int = 0
        var fingerprintsRestored: Bool = false
        var coversImported: Int = 0
    }

    // MARK: - Export

    @MainActor
    static func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Exporter le catalogue ROMdex"
        panel.nameFieldStringValue = defaultExportFileName()

        let accessory = ExportAccessoryView()
        panel.accessoryView = accessory.view

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let includeCovers = accessory.includeCoversCheckbox.state == .on
        do {
            let coverCount = try exportCatalog(to: url, includeCovers: includeCovers)
            if includeCovers, coverCount > 0 {
                CatalogTransferNotifier.shared.announce(
                    "Catalogue exporté (+\(coverCount) vignette(s))."
                )
            } else if includeCovers {
                CatalogTransferNotifier.shared.announce("Catalogue exporté (aucune vignette en cache).")
            } else {
                CatalogTransferNotifier.shared.announce("Catalogue exporté.")
            }
        } catch {
            CatalogTransferNotifier.shared.announce("Échec export : \(error.localizedDescription)")
        }
    }

    static func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "romdex-catalog-\(formatter.string(from: Date())).zip"
    }

    /// - Returns: nombre de fichiers jaquette inclus (0 si non demandé / vide).
    @MainActor
    static func exportCatalog(to zipURL: URL, includeCovers: Bool = false) throws -> Int {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("romdex-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var platformIDs: [String] = []
        for platform in Platform.allCases {
            guard let snapshot = CatalogDiskStore.load(platform) else { continue }
            let data = try encodeSnapshot(snapshot)
            let fileURL = tempRoot.appendingPathComponent("\(platform.rawValue).json")
            try data.write(to: fileURL, options: .atomic)
            platformIDs.append(platform.rawValue)
        }

        guard !platformIDs.isEmpty else {
            throw TransferError.emptyCatalog
        }

        var includeFingerprints = false
        let fpSource = CatalogDiskStore.directoryURL.appendingPathComponent("catalog-fingerprints.json")
        if FileManager.default.fileExists(atPath: fpSource.path) {
            let dest = tempRoot.appendingPathComponent("catalog-fingerprints.json")
            try FileManager.default.copyItem(at: fpSource, to: dest)
            includeFingerprints = true
        }

        var coverCount = 0
        if includeCovers {
            coverCount = try CoverImageDiskCache.shared.copyCachedCovers(toParent: tempRoot)
        }

        let manifest = Manifest(
            app: appID,
            schemaVersion: CatalogSnapshot.currentSchema,
            exportedAt: Date(),
            platforms: platformIDs.sorted(),
            includeFingerprints: includeFingerprints,
            includeCovers: includeCovers && coverCount > 0
        )
        let manifestData = try encodeManifest(manifest)
        try manifestData.write(to: tempRoot.appendingPathComponent(manifestFileName), options: .atomic)

        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try zipDirectory(tempRoot, to: zipURL)
        return coverCount
    }

    // MARK: - Import

    @MainActor
    static func presentImportPanel(mode: ImportMode, onFinished: @escaping (ImportSummary) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = mode == .replace
            ? "Importer le catalogue (remplacer)"
            : "Importer le catalogue (fusionner)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let summary = try importCatalog(from: url, mode: mode)
            onFinished(summary)
        } catch {
            CatalogTransferNotifier.shared.announce("Échec import : \(error.localizedDescription)")
        }
    }

    @MainActor
    static func importCatalog(from zipURL: URL, mode: ImportMode) throws -> ImportSummary {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("romdex-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try unzip(zipURL, to: tempRoot)

        let payloadRoot = try findPayloadRoot(in: tempRoot)
        _ = try? decodeManifest(at: payloadRoot.appendingPathComponent(manifestFileName))

        var summary = ImportSummary()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if mode == .replace {
            CatalogDiskStore.clear()
            CatalogCache.shared.clearMemory()
            CatalogLocalSearch.invalidate()
        }

        let jsonFiles = try FileManager.default.contentsOfDirectory(
            at: payloadRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != manifestFileName }

        for fileURL in jsonFiles {
            let name = fileURL.deletingPathExtension().lastPathComponent
            if name == "catalog-fingerprints" {
                continue
            }
            guard let platform = Platform(rawValue: name) else { continue }
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
            guard !snapshot.results.isEmpty else { continue }

            switch mode {
            case .replace:
                CatalogDiskStore.save(snapshot)
                CatalogCache.shared.store(platform, outcome: snapshot.outcome, persist: false)
                summary.platformsImported += 1
                summary.gamesAdded += snapshot.results.count
            case .merge:
                let previous = CatalogDiskStore.load(platform)?.results ?? []
                let merged = CatalogMerger.mergePreservingEnrichment(
                    previous: previous,
                    scraped: snapshot.results
                )
                let before = Set(previous.map(\.deduplicationKey))
                let added = Set(merged.map(\.deduplicationKey)).subtracting(before).count
                let outcome = SearchOutcome(results: merged, errors: snapshot.errors)
                CatalogDiskStore.save(platform: platform, outcome: outcome)
                CatalogCache.shared.store(platform, outcome: outcome, persist: false)
                summary.platformsImported += 1
                summary.gamesAdded += added
            }
        }

        let fpURL = payloadRoot.appendingPathComponent("catalog-fingerprints.json")
        if FileManager.default.fileExists(atPath: fpURL.path) {
            try CatalogDiskStore.ensureDirectory()
            let dest = CatalogDiskStore.directoryURL.appendingPathComponent("catalog-fingerprints.json")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: fpURL, to: dest)
            CatalogUpdateMonitor.shared.reloadFromDisk()
            summary.fingerprintsRestored = true
        }

        let coversURL = payloadRoot.appendingPathComponent(coversFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: coversURL.path) {
            summary.coversImported = try CoverImageDiskCache.shared.importCovers(
                from: coversURL,
                replaceExisting: mode == .replace
            )
        }

        guard summary.platformsImported > 0 else {
            throw TransferError.noPlatformsInArchive
        }
        return summary
    }

    // MARK: - Accessory (NSSavePanel)

    @MainActor
    private final class ExportAccessoryView: NSObject {
        let view: NSView
        let includeCoversCheckbox: NSButton

        override init() {
            let cache = CoverImageDiskCache.shared
            let title: String
            if cache.hasCachedCovers {
                title = "Inclure les vignettes (\(cache.formattedByteSize))"
            } else {
                title = "Inclure les vignettes (aucune en cache)"
            }

            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            checkbox.state = .off
            checkbox.isEnabled = cache.hasCachedCovers
            checkbox.font = .systemFont(ofSize: NSFont.systemFontSize)
            checkbox.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            checkbox.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
            container.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                checkbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            ])

            self.view = container
            self.includeCoversCheckbox = checkbox
            super.init()
        }
    }

    // MARK: - Encoding

    private static func encodeSnapshot(_ snapshot: CatalogSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    private static func encodeManifest(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private static func decodeManifest(at url: URL) throws -> Manifest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: data)
    }

    private static func findPayloadRoot(in extracted: URL) throws -> URL {
        let manifest = extracted.appendingPathComponent(manifestFileName)
        if FileManager.default.fileExists(atPath: manifest.path) {
            return extracted
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: extracted,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for child in children {
            let nested = child.appendingPathComponent(manifestFileName)
            if FileManager.default.fileExists(atPath: nested.path) {
                return child
            }
            // ZIP sans manifest : dossier contenant des `GBC.json` etc.
            let jsons = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
            if jsons.contains(where: { Platform(rawValue: $0.deletingPathExtension().lastPathComponent) != nil }) {
                return child
            }
        }
        // JSON à la racine sans manifest.
        let rootJSONs = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        if rootJSONs.contains(where: { Platform(rawValue: $0.deletingPathExtension().lastPathComponent) != nil }) {
            return extracted
        }
        throw TransferError.invalidArchive
    }

    // MARK: - ZIP (ditto)

    private static func zipDirectory(_ directory: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // Contenu à plat (sans dossier parent supplémentaire).
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, zipURL.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TransferError.zipFailed(message)
        }
    }

    private static func unzip(_ zipURL: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, directory.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TransferError.unzipFailed(message)
        }
    }

    enum TransferError: LocalizedError {
        case emptyCatalog
        case invalidArchive
        case noPlatformsInArchive
        case zipFailed(String)
        case unzipFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyCatalog:
                return "Aucun catalogue à exporter."
            case .invalidArchive:
                return "Archive invalide (JSON catalogue introuvable)."
            case .noPlatformsInArchive:
                return "Aucun catalogue reconnu dans l’archive."
            case .zipFailed(let msg):
                return "Compression échouée. \(msg)"
            case .unzipFailed(let msg):
                return "Décompression échouée. \(msg)"
            }
        }
    }
}

/// Pont léger pour afficher un toast depuis le menu (hors ViewModel).
@MainActor
final class CatalogTransferNotifier: ObservableObject {
    static let shared = CatalogTransferNotifier()
    @Published var message: String?

    func announce(_ text: String) {
        message = text
    }
}
