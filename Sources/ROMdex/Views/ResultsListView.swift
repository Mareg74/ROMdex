import AppKit
import SwiftUI

struct ResultsListView: View {
    let results: [GameResult]
    @Binding var selectedResult: GameResult?
    let onSelect: (GameResult) -> Void

    var body: some View {
        Group {
            if results.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { result in
                                ResultRowView(
                                    result: result,
                                    isSelected: selectedResult?.deduplicationKey == result.deduplicationKey
                                )
                                .id(result.deduplicationKey)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(result)
                                }

                                if result.id != results.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .background(
                        ListKeyboardMonitor(
                            onUp: { moveSelection(by: -1, proxy: proxy) },
                            onDown: { moveSelection(by: 1, proxy: proxy) }
                        )
                    )
                    .onChange(of: selectedResult?.deduplicationKey) { key in
                        guard let key else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(key, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        guard !results.isEmpty else { return }

        let currentIndex: Int
        if let selected = selectedResult,
           let idx = results.firstIndex(where: { $0.deduplicationKey == selected.deduplicationKey }) {
            currentIndex = idx
        } else {
            currentIndex = delta > 0 ? -1 : results.count
        }

        let next = min(max(currentIndex + delta, 0), results.count - 1)
        let result = results[next]
        onSelect(result)
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(result.deduplicationKey, anchor: .center)
        }
    }
}

/// Capture ↑ / ↓ via moniteur local.
/// Fonctionne même si le champ recherche / filtre a le focus (field editor mono-ligne).
private struct ListKeyboardMonitor: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeNSView(context: Context) -> KeyboardCatcherView {
        let view = KeyboardCatcherView()
        view.onUp = onUp
        view.onDown = onDown
        return view
    }

    func updateNSView(_ nsView: KeyboardCatcherView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
    }

    static func dismantleNSView(_ nsView: KeyboardCatcherView, coordinator: ()) {
        nsView.teardown()
    }
}

private final class KeyboardCatcherView: NSView {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            // Ne pas voler les flèches d’un vrai éditeur multi-ligne.
            if Self.shouldDeferArrowsToTextInput(in: self.window) { return event }
            switch event.keyCode {
            case 126: // ↑
                self.onUp?()
                return nil
            case 125: // ↓
                self.onDown?()
                return nil
            default:
                return event
            }
        }
    }

    func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        teardown()
    }

    /// `true` seulement pour un NSTextView multi-ligne (pas le field editor du champ recherche).
    private static func shouldDeferArrowsToTextInput(in window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? NSTextView else {
            return false
        }
        // Field editor d’un NSTextField : ↑/↓ servent à la liste de résultats.
        if textView.isFieldEditor {
            return false
        }
        return textView.isEditable
    }
}

struct ResultRowView: View {
    let result: GameResult
    var isSelected: Bool = false

    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoverArtView(url: result.thumbnailURL, width: 48, height: 78, cornerRadius: 5)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(result.title)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)

                    HStack(spacing: 4) {
                        ForEach(result.availableRegions.prefix(3)) { region in
                            RegionBadge(region: region, compact: true)
                        }
                        if result.availableRegions.count > 3 {
                            Text("+\(result.availableRegions.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }

                // Étoile sur la même ligne que la console, ancrée à droite.
                HStack(alignment: .center, spacing: 8) {
                    PlatformLabel(platform: result.platform, size: .compact)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    favoriteButton
                        .layoutPriority(2)
                }

                if let genre = result.genre {
                    Text(genre)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 8) {
                    Label(result.sourceNamesSummary, systemImage: "globe")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if result.sourceCount > 1 {
                        Text("·")
                        Text("\(result.sourceCount) sources")
                            .fixedSize()
                    }
                    if let year = result.releaseYear {
                        Text("·")
                        Text(String(year))
                            .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }

    private var favoriteButton: some View {
        let isFav = favorites.isFavorite(result)
        return Button {
            favorites.toggle(result)
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isFav ? Color.yellow : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFav ? "Retirer des favoris" : "Ajouter aux favoris")
    }
}
