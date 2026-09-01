import AppKit
import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var catalog: CatalogViewModel

    /// Largeur fixe = plus long nom de console (+ paddings de la liste).
    private var consoleSidebarWidth: CGFloat {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let headlineFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let names = catalog.platforms.map(\.displayName)
        let bodyWidth = names
            .map { ($0 as NSString).size(withAttributes: [.font: bodyFont]).width }
            .max() ?? 100
        let headerWidth = ("Consoles" as NSString)
            .size(withAttributes: [.font: headlineFont]).width
        // paddings + pastille mise à jour
        let horizontalChrome: CGFloat = 12 + 12
        let badgeAllowance: CGFloat = 18
        return ceil(max(bodyWidth + 8 + 8 + 10 + 10 + badgeAllowance, headerWidth + horizontalChrome)) + 4
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                platformSidebar
                    .frame(width: consoleSidebarWidth)
                    .frame(minWidth: consoleSidebarWidth, maxWidth: consoleSidebarWidth)

                gamesPane
                    .frame(minWidth: 260, idealWidth: 360)

                detailPane
                    .frame(minWidth: 300)
            }

            catalogStatusBar
        }
        .onAppear {
            catalog.refreshTotalCatalogGameCount()
        }
    }

    private var catalogStatusBar: some View {
        HStack(spacing: 12) {
            Text(catalog.platformStatusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(catalog.totalCatalogGameCount.formatted()) jeu(x) au total")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var platformSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Consoles")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(catalog.platforms) { platform in
                    Button {
                        catalog.selectPlatform(platform)
                    } label: {
                        HStack(spacing: 6) {
                            Text(platform.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if catalog.hasInterruptedScrape(for: platform) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                    .help("Scrape interrompu — reprise possible via Actualiser")
                            } else if catalog.hasCatalogUpdate(for: platform) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                    .help("Mise à jour possible")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            catalog.selectedPlatform == platform
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gamesPane: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Filtrer le catalogue…", text: $catalog.filterText)
                    .textFieldStyle(.roundedBorder)
                    .layoutPriority(0)

                Menu {
                    ForEach(CatalogSortOrder.allCases) { order in
                        Button {
                            catalog.sortOrder = order
                        } label: {
                            HStack {
                                Text(order.displayName)
                                if catalog.sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Trier", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .layoutPriority(1)

                RegionFilterMenu(
                    availableRegions: catalog.availableRegions,
                    hiddenRegions: catalog.hiddenRegions,
                    onToggle: catalog.toggleRegionVisibility,
                    onShowAll: catalog.showAllRegions
                )
                .layoutPriority(1)

                SourceFilterMenu(
                    availableSites: catalog.availableSourceSites,
                    hiddenSites: catalog.hiddenSourceSites,
                    onToggle: catalog.toggleSourceSiteVisibility,
                    onShowAll: catalog.showAllSourceSites
                )
                .layoutPriority(1)

                Button {
                    catalog.reload()
                } label: {
                    if catalog.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(catalog.selectedPlatform == nil || catalog.showsBlockingLoader)
                .help(catalog.isLoading
                    ? "\(catalog.scrapeJobs.count) scrape(s) en file…"
                    : "Recharger le catalogue")
                .fixedSize()
                .layoutPriority(1)
            }

            // Progression scrape / enrichissement : ne pas écraser la liste.
            VStack(alignment: .leading, spacing: 6) {
                if catalog.showsBlockingLoader {
                    Text("Chargement du catalogue…")
                        .font(.caption.weight(.semibold))
                }

                if !catalog.scrapeJobs.isEmpty {
                    HStack(spacing: 6) {
                        Text(AppPreferences.catalogScrapeParallel
                            ? "Mode parallèle (max \(AppPreferences.catalogScrapeParallelLimit))"
                            : "Mode séquentiel")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Tout arrêter") {
                            catalog.cancelAllScrapes()
                        }
                        .font(.caption2)
                        .controlSize(.small)
                    }
                    scrapeJobsStack
                }

                if catalog.isCheckingUpdates {
                    Text("Vérification des mises à jour…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let platform = catalog.selectedPlatform,
                   catalog.hasCatalogUpdate(for: platform),
                   !catalog.scrapeJobs.contains(where: { $0.platform == platform }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Text("Catalogue potentiellement mis à jour sur le web.")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Button("Actualiser") {
                            catalog.reload()
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !catalog.updateToasts.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(catalog.updateToasts) { toast in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(toast.listLabel)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(toast.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let platform = toast.resumePlatform {
                                        Button("Reprendre la réactualisation de ce catalogue") {
                                            catalog.resumeInterruptedScrape(
                                                for: platform,
                                                toastID: toast.id
                                            )
                                        }
                                        .font(.caption)
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    catalog.dismissToast(id: toast.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                if catalog.isEnriching,
                   let live = catalog.activeLiveProgress,
                   catalog.scrapeJobs.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        CatalogLiveProgressView(progress: live, compact: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if catalog.isCatalogRebuildRunning {
                            Button {
                                catalog.cancelActiveCatalogRebuild()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Arrêter la reconstruction en cours")
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !catalog.sourceErrors.isEmpty {
                    SourceErrorsView(
                        errors: catalog.sourceErrors,
                        onUnlockRomsFun: { RomsFunUnlockController.shared.present() }
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if catalog.showsBlockingLoader {
                Spacer(minLength: 0)
            } else {
                ResultsListView(
                    results: catalog.results,
                    selectedResult: $catalog.selectedResult,
                    onSelect: catalog.select
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var runningScrapeJobs: [CatalogScrapeJob] {
        catalog.scrapeJobs.filter { $0.phase == .running }
    }

    private var queuedScrapeJobs: [CatalogScrapeJob] {
        catalog.scrapeJobs.filter { $0.phase == .queued }
    }

    private var scrapeJobsStack: some View {
        let rowHeight: CGFloat = 52

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(runningScrapeJobs) { job in
                scrapeJobRow(job)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(height: rowHeight, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !queuedScrapeJobs.isEmpty {
                queuedScrapeJobsModule
            }
        }
    }

    /// Module compact : noms cliquables (retrait unitaire) + ✕ pour vider toute la file.
    private var queuedScrapeJobsModule: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            QueuedConsoleNamesFlow(jobs: queuedScrapeJobs) { jobID in
                catalog.cancelScrape(jobID: jobID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                for job in queuedScrapeJobs {
                    catalog.cancelScrape(jobID: job.id)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Retirer toute la file d’attente")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func scrapeJobRow(_ job: CatalogScrapeJob) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(job.platform.displayName) — en cours")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(discoveredLabel(for: job))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)

                Text(scrapeJobDetailLine1(job))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                catalog.cancelScrape(jobID: job.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Arrêter \(job.platform.displayName)")
        }
    }

    private func discoveredLabel(for job: CatalogScrapeJob) -> String {
        let n = job.discoveredCount
        if n == 0 {
            return "0 jeu découvert"
        }
        return n == 1 ? "1 jeu découvert" : "\(n) jeux découverts"
    }

    private func scrapeJobDetailLine1(_ job: CatalogScrapeJob) -> String {
        guard let live = job.liveProgress else {
            return " "
        }
        var parts: [String] = [live.phaseLabel]
        if let site = live.siteName, !site.isEmpty {
            parts.append(site)
        }
        if let url = live.urlText, !url.isEmpty {
            parts.append(url)
        } else if let title = live.gameTitle, !title.isEmpty {
            parts.append(title)
        }
        return parts.joined(separator: " · ")
    }

    private var detailPane: some View {
        Group {
            if let result = catalog.selectedResult {
                GameDetailView(result: result)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Catalogue par console")
                        .font(.title2)
                    Text("Sélectionnez une console, puis un jeu pour afficher l’aperçu.")
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

private struct CatalogLiveProgressView: View {
    let progress: CatalogLiveProgress
    var compact: Bool = false

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(progress.phaseLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let current = progress.progressIndex,
                   let total = progress.progressTotal,
                   total > 0 {
                    Text("\(current)/\(total)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            if let context = compactContextLine, !context.isEmpty {
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let title = progress.gameTitle, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullBody: some View {
        VStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Text(progress.phaseLabel)
                    .font(.caption.weight(.semibold))
                if let current = progress.progressIndex,
                   let total = progress.progressTotal,
                   total > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(current)/\(total)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let site = progress.siteName {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(site)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let title = progress.gameTitle, !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if let url = progress.urlText, !url.isEmpty {
                Text(url)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            if let detail = progress.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !progress.activeSites.isEmpty {
                Text("Actifs : \(progress.activeSites.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 420, alignment: .center)
    }

    /// Source + console (évite de mélanger phase, compteur et URL sur une seule ligne).
    private var compactContextLine: String? {
        var parts: [String] = []
        if let site = progress.siteName, !site.isEmpty {
            parts.append(site)
        }
        if let detail = progress.detail, !detail.isEmpty {
            parts.append(detail)
        } else if let url = progress.urlText, !url.isEmpty, !url.lowercased().hasPrefix("http") {
            parts.append(url)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Noms de consoles en file, cliquables pour retirer un job unitairement.
private struct QueuedConsoleNamesFlow: View {
    let jobs: [CatalogScrapeJob]
    let onRemove: (UUID) -> Void

    var body: some View {
        FlowLayout(spacing: 0, lineSpacing: 2) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                HStack(spacing: 0) {
                    if index > 0 {
                        Text(", ")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onRemove(job.id)
                    } label: {
                        Text(job.platform.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .underline(color: Color.secondary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Retirer \(job.platform.displayName) de la file")
                }
            }
        }
    }
}

/// Disposition qui enroule les sous-vues sur plusieurs lignes.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widthUsed: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            widthUsed = max(widthUsed, x - spacing)
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : widthUsed, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
