import SwiftUI

/// Menu de filtrage des sources (cases cochées = visibles).
struct SourceFilterMenu: View {
    let availableSites: [String]
    /// Invalide le rendu quand le set masqué change (UserDefaults).
    let hiddenSites: Set<String>
    let onToggle: (String) -> Void
    let onShowAll: () -> Void

    private var visibleCount: Int {
        availableSites.filter { !hiddenSites.contains($0) }.count
    }

    private var summary: String {
        guard !availableSites.isEmpty else { return "—" }
        if hiddenSites.isEmpty || visibleCount == availableSites.count {
            return "Toutes"
        }
        if visibleCount == 0 {
            return "Aucune"
        }
        let visible = availableSites.filter { !hiddenSites.contains($0) }
        if visible.count <= 2 {
            return visible.joined(separator: ", ")
        }
        return "\(visible.count)/\(availableSites.count)"
    }

    var body: some View {
        Menu {
            Button("Toutes") {
                onShowAll()
            }
            .disabled(hiddenSites.isEmpty)

            if !availableSites.isEmpty {
                Divider()

                ForEach(availableSites, id: \.self) { site in
                    Button {
                        onToggle(site)
                    } label: {
                        HStack {
                            Text(site)
                            Spacer()
                            if !hiddenSites.contains(site) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Sources", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(availableSites.isEmpty)
        .help(availableSites.isEmpty
            ? "Aucune source dans cette liste"
            : "Afficher / masquer les sources (\(summary))")
    }
}
