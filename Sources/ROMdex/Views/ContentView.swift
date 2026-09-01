import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: SearchViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 360)

            detailPane
                .frame(minWidth: 300)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            SearchControlsView()

            if viewModel.isSearching {
                ProgressView(
                    viewModel.results.isEmpty
                        ? "Recherche multi-sites…"
                        : "Enrichissement depuis le web…"
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !viewModel.sourceErrors.isEmpty {
                SourceErrorsView(
                    errors: viewModel.sourceErrors,
                    onUnlockRomsFun: { RomsFunUnlockController.shared.present() }
                )
            }

            ResultsListView(
                results: viewModel.results,
                selectedResult: $viewModel.selectedResult,
                onSelect: viewModel.select
            )
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailPane: some View {
        Group {
            if let result = viewModel.selectedResult {
                GameDetailView(result: result)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Sélectionnez un jeu")
                        .font(.title2)
                    Text("Choisissez un résultat pour afficher l’aperçu de la page source.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SearchControlsView: View {
    @EnvironmentObject private var viewModel: SearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchTextField(
                text: $viewModel.query,
                placeholder: "Tapez pour rechercher…",
                onSubmit: viewModel.search
            )
            .frame(height: 28)

            HStack(alignment: .top, spacing: 8) {
                MultiSelectMenu(
                    title: "Plateforme",
                    summary: platformsSummary,
                    clearLabel: "Toutes"
                ) {
                    Button("Toutes") {
                        viewModel.clearPlatforms()
                    }

                    Divider()

                    ForEach(Platform.allCases) { platform in
                        Button {
                            viewModel.togglePlatform(platform)
                        } label: {
                            HStack {
                                Text(platform.displayName)
                                Spacer()
                                if viewModel.selectedPlatforms.contains(platform) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                MultiSelectMenu(
                    title: "Région",
                    summary: regionsSummary,
                    clearLabel: "Toutes"
                ) {
                    Button("Toutes") {
                        viewModel.clearRegions()
                    }

                    Divider()

                    ForEach(GameRegion.allCases) { region in
                        Button {
                            viewModel.toggleRegion(region)
                        } label: {
                            HStack {
                                Text("\(region.flagEmoji) \(region.fullName)")
                                Spacer()
                                if viewModel.selectedRegions.contains(region) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                SourceFilterMenu(
                    availableSites: viewModel.availableSourceSites,
                    hiddenSites: viewModel.hiddenSourceSites,
                    onToggle: viewModel.toggleSourceSiteVisibility,
                    onShowAll: viewModel.showAllSourceSites
                )
            }

            HStack {
                Button("Rechercher", action: viewModel.search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !viewModel.historyStore.entries.isEmpty {
                    Menu("Historique") {
                        ForEach(viewModel.historyStore.entries) { entry in
                            Button(historyLabel(for: entry)) {
                                viewModel.applyHistory(entry)
                            }
                        }

                        Divider()

                        Button("Effacer l’historique", role: .destructive) {
                            viewModel.historyStore.clear()
                        }
                    }
                }
            }
        }
    }

    private var platformsSummary: String {
        if viewModel.selectedPlatforms.isEmpty {
            return "Toutes"
        }
        let names = viewModel.selectedPlatforms.map(\.displayName).sorted()
        if names.count <= 2 {
            return names.joined(separator: ", ")
        }
        return "\(names.count) sélectionnées"
    }

    private var regionsSummary: String {
        if viewModel.selectedRegions.isEmpty {
            return "Toutes"
        }
        let names = viewModel.selectedRegions.map(\.displayName).sorted()
        if names.count <= 3 {
            return names.joined(separator: ", ")
        }
        return "\(names.count) sélectionnées"
    }

    private func historyLabel(for entry: SearchHistoryEntry) -> String {
        var parts = [entry.query]
        if !entry.platforms.isEmpty {
            parts.append(entry.platforms.map(\.displayName).joined(separator: "+"))
        }
        if !entry.regions.isEmpty {
            parts.append(entry.regions.map(\.displayName).joined(separator: "+"))
        }
        return parts.joined(separator: " — ")
    }
}

struct MultiSelectMenu<Content: View>: View {
    let title: String
    let summary: String
    let clearLabel: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                content()
            } label: {
                HStack {
                    Text(summary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
            }
            .menuStyle(.borderlessButton)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SourceErrorsView: View {
    let errors: [String]
    var onUnlockRomsFun: (() -> Void)? = nil

    private var showsRomsFunUnlock: Bool {
        guard onUnlockRomsFun != nil else { return false }
        return errors.contains { error in
            let lower = error.lowercased()
            return lower.contains("romsfun") && (lower.contains("bloqué") || lower.contains("anti-bot"))
        }
    }

    var body: some View {
        DisclosureGroup("Sources indisponibles (\(errors.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(errors, id: \.self) { error in
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if showsRomsFunUnlock, let onUnlockRomsFun {
                    Button("Débloquer RomsFun…") {
                        onUnlockRomsFun()
                    }
                    .font(.caption)
                }
            }
        }
        .font(.caption)
    }
}
