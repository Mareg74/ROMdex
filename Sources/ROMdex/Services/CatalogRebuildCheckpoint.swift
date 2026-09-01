import AppKit
import Foundation

/// Point de reprise pour les reconstructions dates / vignettes.
struct CatalogRebuildCheckpoint: Codable, Equatable {
    enum Kind: String, Codable {
        case dates
        case thumbnails
    }

    var kind: Kind
    var processedIndex: Int
    var totalGames: Int
    var catalogFingerprint: String
    var interrupted: Bool
    var updatedAt: Date
}

enum CatalogRebuildResumeChoice {
    case resume
    case restart
    case cancel
}

enum CatalogRebuildCheckpointStore {
    private static let folderName = "RebuildCheckpoints"

    private static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ROMdex", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func fileURL(for kind: CatalogRebuildCheckpoint.Kind) -> URL {
        directoryURL.appendingPathComponent("\(kind.rawValue).json", isDirectory: false)
    }

    static func catalogFingerprint(outcomes: [(Platform, SearchOutcome)]) -> String {
        outcomes
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .map { "\($0.0.rawValue):\($0.1.results.count)" }
            .joined(separator: "|")
    }

    static func load(_ kind: CatalogRebuildCheckpoint.Kind) -> CatalogRebuildCheckpoint? {
        let url = fileURL(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let checkpoint = try decoder.decode(CatalogRebuildCheckpoint.self, from: data)
            guard checkpoint.kind == kind else { return nil }
            return checkpoint
        } catch {
            return nil
        }
    }

    static func save(_ checkpoint: CatalogRebuildCheckpoint) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(checkpoint)
            let url = fileURL(for: checkpoint.kind)
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

    static func clear(_ kind: CatalogRebuildCheckpoint.Kind) {
        let url = fileURL(for: kind)
        try? FileManager.default.removeItem(at: url)
    }

    static func saveInterrupted(
        kind: CatalogRebuildCheckpoint.Kind,
        processedIndex: Int,
        totalGames: Int,
        catalogFingerprint: String
    ) {
        guard processedIndex > 0, processedIndex < totalGames else {
            clear(kind)
            return
        }
        save(
            CatalogRebuildCheckpoint(
                kind: kind,
                processedIndex: processedIndex,
                totalGames: totalGames,
                catalogFingerprint: catalogFingerprint,
                interrupted: true,
                updatedAt: .now
            )
        )
    }

    @MainActor
    static func prompt(
        kind: CatalogRebuildCheckpoint.Kind,
        checkpoint: CatalogRebuildCheckpoint,
        catalogFingerprint: String
    ) -> CatalogRebuildResumeChoice {
        guard checkpoint.interrupted,
              checkpoint.processedIndex > 0,
              checkpoint.processedIndex < checkpoint.totalGames else {
            clear(kind)
            return .restart
        }

        guard checkpoint.catalogFingerprint == catalogFingerprint else {
            clear(kind)
            let alert = NSAlert()
            alert.messageText = kind.title
            alert.informativeText = """
            Le catalogue a changé depuis la dernière opération interrompue. \
            La reprise n’est pas possible — une nouvelle passe sera lancée.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Continuer")
            alert.runModal()
            return .restart
        }

        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = """
        Une opération précédente s’est arrêtée à \
        \(checkpoint.processedIndex)/\(checkpoint.totalGames) jeux en base.

        Reprendre où vous en étiez, ou recommencer depuis le début ?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reprendre")
        alert.addButton(withTitle: "Recommencer depuis le début")
        alert.addButton(withTitle: "Annuler")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .resume
        case .alertSecondButtonReturn:
            clear(kind)
            return .restart
        default:
            return .cancel
        }
    }
}

private extension CatalogRebuildCheckpoint.Kind {
    var title: String {
        switch self {
        case .dates: return "Reprendre la mise à jour des dates ?"
        case .thumbnails: return "Reprendre la mise à jour des vignettes ?"
        }
    }
}
