import Foundation

struct SearchHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let query: String
    let platforms: [Platform]
    let regions: [GameRegion]
    let date: Date

    init(
        id: UUID = UUID(),
        query: String,
        platforms: Set<Platform> = [],
        regions: Set<GameRegion> = [],
        date: Date = .now
    ) {
        self.id = id
        self.query = query
        self.platforms = platforms.sorted { $0.displayName < $1.displayName }
        self.regions = regions.sorted { $0.displayName < $1.displayName }
        self.date = date
    }

    var platformsSet: Set<Platform> { Set(platforms) }
    var regionsSet: Set<GameRegion> { Set(regions) }
}

@MainActor
final class SearchHistoryStore: ObservableObject {
    @Published private(set) var entries: [SearchHistoryEntry] = []

    private let storageKey = "romdex.search.history.v2"
    private let maxEntries = 20

    init() {
        load()
    }

    func record(query: String, platforms: Set<Platform>, regions: Set<GameRegion>) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.removeAll {
            $0.query.caseInsensitiveCompare(trimmed) == .orderedSame
                && Set($0.platforms) == platforms
                && Set($0.regions) == regions
        }

        entries.insert(
            SearchHistoryEntry(query: trimmed, platforms: platforms, regions: regions),
            at: 0
        )

        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        entries = (try? JSONDecoder().decode([SearchHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
