import AppKit
import SwiftUI
import WebKit

struct GameDetailView: View {
    let result: GameResult
    @State private var selectedSourceID: UUID?

    private var selectedSource: GameSource {
        if let selectedSourceID,
           let match = result.sources.first(where: { $0.id == selectedSourceID }) {
            return match
        }
        return result.primarySource
    }

    private var showsMultipleRegions: Bool {
        result.availableRegions.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            sourcePicker

            Divider()

            WebPreviewView(url: selectedSource.pageURL)
                .id(selectedSource.pageURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedSourceID = result.primarySource.id
            PagePreviewCache.shared.preload(selectedSource.pageURL)
        }
        .onChange(of: result.id) { _ in
            selectedSourceID = result.primarySource.id
            PagePreviewCache.shared.preload(result.primarySource.pageURL)
        }
        .onChange(of: selectedSourceID) { newID in
            guard let newID,
                  let source = result.sources.first(where: { $0.id == newID }) else { return }
            PagePreviewCache.shared.preload(source.pageURL)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            narrowHeader
        }
    }

    private var wideHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            coverArt(width: 120, height: 196)

            VStack(alignment: .leading, spacing: 10) {
                Text(result.title)
                    .font(.title2.bold())
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                metadataRow(platformSize: .large)

                urlLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            openBrowserButton
                .controlSize(.large)
                .layoutPriority(1)
                .fixedSize()
        }
    }

    private var narrowHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                coverArt(width: 88, height: 144)

                VStack(alignment: .leading, spacing: 8) {
                    Text(result.title)
                        .font(.title3.bold())
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    metadataRow(platformSize: .compact)

                    urlLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            openBrowserButton
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
        }
    }

    private func coverArt(width: CGFloat, height: CGFloat) -> some View {
        CoverArtView(
            url: selectedSource.thumbnailURL ?? result.thumbnailURL,
            width: width,
            height: height,
            cornerRadius: 8
        )
        .layoutPriority(1)
    }

    private func metadataRow(platformSize: PlatformLabelSize) -> some View {
        // Scroll horizontal évite la compression « sw S » quand l’espace manque.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PlatformLabel(platform: result.platform, size: platformSize)
                    .fixedSize()

                RegionBadge(region: selectedSource.region)

                if let year = result.releaseYear {
                    Text(String(year))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                if let genre = result.genre {
                    Text(genre)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
            }
        }
    }

    private var urlLine: some View {
        Text(selectedSource.pageURL.absoluteString)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var openBrowserButton: some View {
        Button {
            NSWorkspace.shared.open(selectedSource.pageURL)
        } label: {
            Label("Ouvrir dans le navigateur", systemImage: "safari")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.sourceCount > 1 ? "Sources disponibles" : "Source")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(result.sources) { source in
                        Button {
                            if selectedSource.id == source.id {
                                PagePreviewCache.shared.reload(source.pageURL)
                            } else {
                                selectedSourceID = source.id
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if showsMultipleRegions || result.sourceCount == 1 {
                                    RegionBadge(region: source.region, compact: true)
                                }
                                Text(source.siteName)
                                    .font(.subheadline.weight(selectedSource.id == source.id ? .semibold : .regular))
                                    .lineLimit(1)
                                if source.thumbnailURL != nil {
                                    Image(systemName: "photo")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectedSource.id == source.id
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.secondary.opacity(0.12)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        selectedSource.id == source.id
                                            ? Color.accentColor.opacity(0.5)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help(
                            selectedSource.id == source.id
                                ? "\(source.siteName) — recliquer pour actualiser\n\(source.pageURL.absoluteString)"
                                : "\(source.siteName) — \(source.region.fullName)\n\(source.pageURL.absoluteString)"
                        )
                    }
                }
            }
        }
    }
}

struct WebPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebViewHost {
        let host = WKWebViewHost()
        host.show(url: url)
        return host
    }

    func updateNSView(_ nsView: WKWebViewHost, context: Context) {
        nsView.show(url: url)
    }
}

/// Héberge une `WKWebView` provenant du cache LRU (réattachable).
final class WKWebViewHost: NSView {
    private weak var currentWebView: WKWebView?
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(url: URL) {
        if currentURL == url, let existing = currentWebView, existing.superview === self {
            return
        }

        currentWebView?.removeFromSuperview()
        currentURL = url

        let webView = PagePreviewCache.shared.webView(for: url)
        if webView.superview === self {
            currentWebView = webView
            return
        }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        currentWebView = webView
    }
}
