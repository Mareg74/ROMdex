import AppKit
import SwiftUI

/// Contrôle le popup d’agrandissement des jaquettes (overlay fenêtre).
@MainActor
final class CoverArtLightboxController: ObservableObject {
    static let shared = CoverArtLightboxController()

    @Published private(set) var image: NSImage?
    @Published private(set) var isPresented = false

    private var dismissTask: Task<Void, Never>?

    func present(_ image: NSImage) {
        dismissTask?.cancel()
        self.image = image
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            isPresented = true
        }
    }

    func dismiss() {
        guard isPresented else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, !self.isPresented else { return }
            self.image = nil
        }
    }
}

/// Jacquette dont le cadre épouse le ratio réel (carré, portrait, paysage).
struct CoverArtView: View {
    let url: URL?
    /// Emprise max (le cadre se réduit au ratio de l’image).
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 6
    /// Clic → agrandissement en popup.
    var allowsExpansion: Bool = true

    @EnvironmentObject private var lightbox: CoverArtLightboxController
    @EnvironmentObject private var coverDiskCache: CoverImageDiskCache
    @StateObject private var loader = CoverImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                let size = fittedSize(for: image.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard allowsExpansion else { return }
                        lightbox.present(image)
                    }
                    .help(allowsExpansion ? "Cliquer pour agrandir" : "")
            } else if loader.failed || url == nil {
                placeholder
            } else {
                ProgressView()
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .frame(maxWidth: width, maxHeight: height, alignment: .center)
        .accessibilityLabel("Jacquette")
        .task(id: "\(url?.absoluteString ?? "")|\(coverDiskCache.preferMaximumQuality)") {
            await loader.load(url)
        }
    }

    private var placeholderSize: CGSize {
        fittedSize(aspectRatio: 2.0 / 3.0)
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: min(placeholderSize.width, placeholderSize.height) * 0.28))
            .foregroundStyle(.secondary)
            .frame(width: placeholderSize.width, height: placeholderSize.height)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }
    }

    private func fittedSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return placeholderSize
        }
        return fittedSize(aspectRatio: imageSize.width / imageSize.height)
    }

    private func fittedSize(aspectRatio: CGFloat) -> CGSize {
        guard aspectRatio > 0 else {
            return CGSize(width: width, height: height)
        }
        let heightIfFullWidth = width / aspectRatio
        if heightIfFullWidth <= height {
            return CGSize(width: width, height: heightIfFullWidth)
        }
        return CGSize(width: height * aspectRatio, height: height)
    }
}

/// Fond assombri + jaquette agrandie ; clic image ou alentours → fermeture.
struct CoverArtLightboxOverlay: View {
    @EnvironmentObject private var lightbox: CoverArtLightboxController

    var body: some View {
        ZStack {
            if let image = lightbox.image {
                Color.black
                    .opacity(lightbox.isPresented ? 0.78 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { lightbox.dismiss() }

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(
                        color: .black.opacity(lightbox.isPresented ? 0.5 : 0),
                        radius: lightbox.isPresented ? 32 : 8,
                        y: lightbox.isPresented ? 14 : 4
                    )
                    .padding(48)
                    .scaleEffect(lightbox.isPresented ? 1 : 0.88)
                    .opacity(lightbox.isPresented ? 1 : 0)
                    .offset(y: lightbox.isPresented ? 0 : 18)
                    .contentShape(Rectangle())
                    .onTapGesture { lightbox.dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(lightbox.isPresented)
        .onExitCommand {
            if lightbox.isPresented {
                lightbox.dismiss()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jacquette agrandie")
        .accessibilityAddTraits(.isModal)
        .accessibilityHidden(!lightbox.isPresented)
    }
}

@MainActor
private final class CoverImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false

    private var loadedKey: String?

    func load(_ url: URL?) async {
        guard let url else {
            image = nil
            failed = true
            loadedKey = nil
            return
        }

        let maxQuality = CoverImageDiskCache.shared.preferMaximumQuality
        let key = "\(url.absoluteString)|\(maxQuality)"
        if loadedKey == key, image != nil { return }

        image = nil
        failed = false
        loadedKey = key

        let candidates = CoverArtParser.loadCandidates(for: url)
        let cache = CoverImageDiskCache.shared

        // Mode normal : disque d’abord (évite le réseau au redémarrage).
        if !maxQuality {
            for candidate in candidates {
                if let cached = cache.loadImage(forRemoteURL: candidate) {
                    guard !Task.isCancelled, loadedKey == key else { return }
                    image = cached
                    return
                }
            }
        }

        for candidate in candidates {
            if let loaded = await fetchImage(candidate) {
                guard !Task.isCancelled, loadedKey == key else { return }
                image = loaded
                // Toujours stocker une version JPEG allégée — jamais la HQ brute.
                cache.store(image: loaded, forRemoteURL: candidate)
                // Aussi sous l’URL catalogue d’origine si différente (lookup au prochain lancement).
                if candidate != url {
                    cache.store(image: loaded, forRemoteURL: url)
                }
                return
            }
        }

        // Qualité max échouée : repli sur le cache local s’il existe.
        if maxQuality {
            for candidate in candidates {
                if let cached = cache.loadImage(forRemoteURL: candidate) {
                    guard !Task.isCancelled, loadedKey == key else { return }
                    image = cached
                    return
                }
            }
        }

        guard !Task.isCancelled, loadedKey == key else { return }
        failed = true
    }

    private func fetchImage(_ url: URL) async -> NSImage? {
        do {
            let data: Data
            if WebKitCookieBridge.needsWebKitCookies(for: url) {
                // Cloudflare : cookies WK + Referer (URLSession nu → 403).
                data = try await WebKitCookieBridge.fetchData(from: url)
            } else {
                let (raw, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                    return nil
                }
                data = raw
            }
            guard let loaded = NSImage(data: data), loaded.size.width > 0 else { return nil }
            return loaded
        } catch {
            return nil
        }
    }
}
