import AppKit
import Foundation

/// Reprise d'un scrape catalogue interrompu (sources déjà terminées ignorées au prochain lancement).
enum CatalogScrapeCheckpointStore {
    private static let folderName = "ScrapeCheckpoints"

    struct Checkpoint: Codable, Equatable {
        var platformRawValue: String
        var completedAdapterIds: [String]
        var totalAdapters: Int
        var adapterSetFingerprint: String
        var interrupted: Bool
        var updatedAt: Date
    }

    enum PromptAction {
        case resume
        case restart
        case cancel
    }

    private static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ROMdex", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func adapterFingerprint(adapterIds: [String]) -> String {
        adapterIds.sorted().joined(separator: "|")
    }

    static func load(_ platform: Platform) -> Checkpoint? {
        let url = fileURL(for: platform)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Checkpoint.self, from: data)
        } catch {
            return nil
        }
    }

    static func save(_ checkpoint: Checkpoint, for platform: Platform) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(checkpoint)
            let url = fileURL(for: platform)
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

    static func clear(_ platform: Platform) {
        let url = fileURL(for: platform)
        try? FileManager.default.removeItem(at: url)
    }

    static func hasInterruptedScrape(for platform: Platform, adapterFingerprint: String) -> Bool {
        guard let checkpoint = load(platform), checkpoint.interrupted else { return false }
        return checkpoint.adapterSetFingerprint == adapterFingerprint
            && !checkpoint.completedAdapterIds.isEmpty
            && checkpoint.completedAdapterIds.count < checkpoint.totalAdapters
    }

    static func interruptedPlatforms(adapterFingerprint: String) -> [Platform] {
        Platform.allCases.filter { hasInterruptedScrape(for: $0, adapterFingerprint: adapterFingerprint) }
    }

    static func prompt(
        platform: Platform,
        checkpoint: Checkpoint,
        adapterFingerprint: String
    ) -> PromptAction {
        guard checkpoint.adapterSetFingerprint == adapterFingerprint else {
            return staleCheckpointAlert(platform: platform)
        }

        let done = checkpoint.completedAdapterIds.count
        let total = max(checkpoint.totalAdapters, 1)
        let remaining = max(0, total - done)

        let alert = NSAlert()
        alert.messageText = "Scrape interrompu — \(platform.displayName)"
        alert.informativeText = """
        \(done) source(s) sur \(total) déjà terminée(s) lors de la dernière actualisation.

        Reprendre ne rescrape que les \(remaining) source(s) restante(s).
        Recommencer relance toutes les sources depuis le début.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reprendre")
        alert.addButton(withTitle: "Recommencer")
        alert.addButton(withTitle: "Annuler")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .resume
        case .alertSecondButtonReturn:
            clear(platform)
            return .restart
        default:
            return .cancel
        }
    }

    private static func staleCheckpointAlert(platform: Platform) -> PromptAction {
        let alert = NSAlert()
        alert.messageText = "Point de reprise obsolète"
        alert.informativeText = """
        La liste des sources a changé depuis la dernière interruption.
        Le point de reprise sera ignoré et un scrape complet sera lancé.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Scrape complet")
        alert.addButton(withTitle: "Annuler")

        if alert.runModal() == .alertFirstButtonReturn {
            clear(platform)
            return .restart
        }
        return .cancel
    }

    private static func fileURL(for platform: Platform) -> URL {
        directoryURL.appendingPathComponent("scrape-\(platform.rawValue).json", isDirectory: false)
    }
}
