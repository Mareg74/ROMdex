import Foundation

protocol SiteAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }
    func search(query: String, platform: Platform?) async throws -> [GameResult]

    /// Catalogue complet (ou partiel paginé) pour une console. Défaut : non supporté.
    func browse(platform: Platform) async throws -> [GameResult]
}

extension SiteAdapter {
    func browse(platform: Platform) async throws -> [GameResult] {
        []
    }
}

enum SiteAdapterError: LocalizedError {
    case unsupportedPlatform(Platform)
    case invalidResponse
    case notFound(String)
    case blocked(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let platform):
            return "\(platform.displayName) n'est pas pris en charge par cette source."
        case .invalidResponse:
            return "Réponse invalide du site."
        case .notFound(let site):
            return "\(site) : page introuvable (404)."
        case .blocked(let site):
            return "\(site) a bloqué la requête (protection anti-bot)."
        case .network(let error):
            return error.localizedDescription
        }
    }
}

/// Filtre les erreurs transitoires (annulation utilisateur, requêtes coupées).
enum ScrapeErrorFilter {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
            return true
        }
        let lower = error.localizedDescription.lowercased()
        return lower == "cancelled"
            || lower.contains("cancellationerror")
            || (lower.contains("operation couldn't be completed") && lower.contains("cancel"))
    }

    /// Erreurs à ne pas afficher ni persister dans le catalogue.
    static func isTransientStoredError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.hasSuffix(": cancelled") { return true }
        if lower.contains("cancellationerror") { return true }
        if lower.contains("operation couldn't be completed"), lower.contains("cancel") {
            return true
        }
        return false
    }

    static func filterStoredErrors(_ errors: [String]) -> [String] {
        errors.filter { !isTransientStoredError($0) }
    }

    static func formatBrowseError(adapterName: String, error: Error) -> String? {
        guard !isCancellation(error) else { return nil }
        if let siteError = error as? SiteAdapterError {
            return "\(adapterName): \(siteError.localizedDescription)"
        }
        return "\(adapterName): \(error.localizedDescription)"
    }
}
