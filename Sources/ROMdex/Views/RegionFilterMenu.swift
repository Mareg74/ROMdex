import SwiftUI

/// Menu de filtrage des régions (cases cochées = visibles).
struct RegionFilterMenu: View {
    let availableRegions: [GameRegion]
    /// Invalide le rendu quand le set masqué change (UserDefaults).
    let hiddenRegions: Set<GameRegion>
    let onToggle: (GameRegion) -> Void
    let onShowAll: () -> Void

    private var visibleCount: Int {
        availableRegions.filter { !hiddenRegions.contains($0) }.count
    }

    private var summary: String {
        guard !availableRegions.isEmpty else { return "—" }
        if hiddenRegions.isEmpty || visibleCount == availableRegions.count {
            return "Toutes"
        }
        if visibleCount == 0 {
            return "Aucune"
        }
        let visible = availableRegions.filter { !hiddenRegions.contains($0) }
        if visible.count <= 3 {
            return visible.map(\.displayName).joined(separator: ", ")
        }
        return "\(visible.count)/\(availableRegions.count)"
    }

    var body: some View {
        Menu {
            Button("Toutes") {
                onShowAll()
            }
            .disabled(hiddenRegions.isEmpty)

            if !availableRegions.isEmpty {
                Divider()

                ForEach(availableRegions) { region in
                    Button {
                        onToggle(region)
                    } label: {
                        HStack {
                            Text("\(region.flagEmoji) \(region.fullName)")
                            Spacer()
                            if !hiddenRegions.contains(region) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Régions", systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(availableRegions.isEmpty)
        .help(availableRegions.isEmpty
            ? "Aucune région dans cette liste"
            : "Afficher / masquer les régions (\(summary))")
    }
}
