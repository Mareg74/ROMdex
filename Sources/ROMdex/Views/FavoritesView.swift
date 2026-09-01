import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @State private var selectedResult: GameResult?
    @State private var filterText = ""
    @State private var hiddenSourceSites: Set<String> = AppPreferences.hiddenSourceSites

    private var filtered: [GameResult] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = favorites.favorites

        if !hiddenSourceSites.isEmpty {
            list = list.compactMap { $0.restrictingSources(hidingSiteNames: hiddenSourceSites) }
        }

        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.title.lowercased().contains(needle)
                || $0.platform.displayName.lowercased().contains(needle)
                || ($0.genre?.lowercased().contains(needle) ?? false)
        }
    }

    private var availableSourceSites: [String] {
        GameResult.availableSourceSiteNames(in: favorites.favorites)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Filtrer les favoris…", text: $filterText)
                        .textFieldStyle(.roundedBorder)

                    SourceFilterMenu(
                        availableSites: availableSourceSites,
                        hiddenSites: hiddenSourceSites,
                        onToggle: toggleSourceSiteVisibility,
                        onShowAll: showAllSourceSites
                    )

                    if !favorites.favorites.isEmpty {
                        Button("Tout retirer") {
                            favorites.clear()
                            selectedResult = nil
                        }
                        .disabled(favorites.favorites.isEmpty)
                    }
                }

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(favorites.favorites.isEmpty ? "Aucun favori" : "Aucun résultat")
                            .font(.headline)
                        Text(
                            favorites.favorites.isEmpty
                                ? "Cliquez sur l’étoile dans une liste pour ajouter un jeu."
                                : "Modifiez le filtre pour afficher d’autres favoris."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ResultsListView(
                        results: filtered,
                        selectedResult: $selectedResult,
                        onSelect: { selectedResult = $0 }
                    )
                }
            }
            .padding()
            .frame(minWidth: 260, idealWidth: 360)
            .background(Color(nsColor: .windowBackgroundColor))

            Group {
                if let result = selectedResult {
                    GameDetailView(result: result)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Favoris")
                            .font(.title2)
                        Text("Sélectionnez un jeu favori pour afficher l’aperçu.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onChange(of: favorites.favorites) { _ in
            if let selected = selectedResult,
               !favorites.isFavorite(selected) {
                selectedResult = nil
            }
        }
        .onAppear {
            hiddenSourceSites = AppPreferences.hiddenSourceSites
        }
    }

    private func toggleSourceSiteVisibility(_ siteName: String) {
        AppPreferences.toggleSourceSiteVisibility(siteName)
        hiddenSourceSites = AppPreferences.hiddenSourceSites
        if let selected = selectedResult,
           !filtered.contains(where: { $0.id == selected.id }) {
            selectedResult = nil
        }
    }

    private func showAllSourceSites() {
        AppPreferences.showAllSourceSites()
        hiddenSourceSites = AppPreferences.hiddenSourceSites
    }

    private var statusLine: String {
        if favorites.favorites.isEmpty {
            return "Aucun jeu en favori."
        }
        let hasTextFilter = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSourceFilter = !hiddenSourceSites.isEmpty
        if hasTextFilter || hasSourceFilter {
            var notes: [String] = []
            if hasTextFilter { notes.append("texte") }
            if hasSourceFilter { notes.append("\(hiddenSourceSites.count) source(s) masquée(s)") }
            return "\(filtered.count) / \(favorites.favorites.count) favori(s) (filtre : \(notes.joined(separator: " · ")))"
        }
        return "\(favorites.favorites.count) favori(s)"
    }
}
