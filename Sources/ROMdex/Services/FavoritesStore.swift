import Foundation

/// Favoris persistés (clé stable = titre + plateforme, pas l’UUID volatile).
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [GameResult] = []

    private let storageKey = "romdex.favorites.v1"

    init() {
        load()
    }

    func isFavorite(_ result: GameResult) -> Bool {
        favorites.contains { $0.deduplicationKey == result.deduplicationKey }
    }

    func toggle(_ result: GameResult) {
        if isFavorite(result) {
            remove(result)
        } else {
            add(result)
        }
    }

    func add(_ result: GameResult) {
        favorites.removeAll { $0.deduplicationKey == result.deduplicationKey }
        favorites.insert(result, at: 0)
        save()
    }

    func remove(_ result: GameResult) {
        favorites.removeAll { $0.deduplicationKey == result.deduplicationKey }
        save()
    }

    func clear() {
        favorites = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        favorites = (try? JSONDecoder().decode([GameResult].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
