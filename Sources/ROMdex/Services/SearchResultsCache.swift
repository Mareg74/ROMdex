import Foundation

struct CachedSearchSnapshot: Identifiable, Hashable {
    var id: String { cacheKey }
    let cacheKey: String
    let query: String
    let platforms: Set<Platform>
    let results: [GameResult]
    let errors: [String]
    let date: Date

    init(
        query: String,
        platforms: Set<Platform>,
        results: [GameResult],
        errors: [String],
        date: Date = .now
    ) {
        self.query = query
        self.platforms = platforms
        self.results = results
        self.errors = errors
        self.date = date
        self.cacheKey = Self.makeKey(query: query, platforms: platforms)
    }

    static func makeKey(query: String, platforms: Set<Platform>) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let platformKey = platforms.isEmpty
            ? "all"
            : platforms.map(\.rawValue).sorted().joined(separator: ",")
        return "\(normalized)|\(platformKey)"
    }
}

@MainActor
final class SearchResultsCache {
    static let shared = SearchResultsCache()

    private let maxEntries = 10
    private(set) var snapshots: [CachedSearchSnapshot] = []

    private init() {}

    func store(query: String, platforms: Set<Platform>, results: [GameResult], errors: [String]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let snapshot = CachedSearchSnapshot(
            query: trimmed,
            platforms: platforms,
            results: results,
            errors: errors
        )

        snapshots.removeAll { $0.cacheKey == snapshot.cacheKey }
        snapshots.insert(snapshot, at: 0)

        if snapshots.count > maxEntries {
            snapshots = Array(snapshots.prefix(maxEntries))
        }
    }

    func lookup(query: String, platforms: Set<Platform>) -> CachedSearchSnapshot? {
        let key = CachedSearchSnapshot.makeKey(query: query, platforms: platforms)
        guard let index = snapshots.firstIndex(where: { $0.cacheKey == key }) else {
            return nil
        }

        let snapshot = snapshots.remove(at: index)
        snapshots.insert(snapshot, at: 0)
        return snapshot
    }

    func clear() {
        snapshots.removeAll()
    }
}
