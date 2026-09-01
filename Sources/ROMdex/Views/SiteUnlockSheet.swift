import AppKit
import SwiftUI
import WebKit

/// Feuille : WebView visible pour valider Cloudflare, cookies dans `WKWebsiteDataStore.default()`.
struct SiteUnlockSheet: View {
    let siteName: String
    let url: URL
    var onUnlocked: () -> Void
    var onCancel: () -> Void

    @StateObject private var model = SiteUnlockModel()
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            UnlockWebView(url: url, model: model)
                .frame(minWidth: 720, minHeight: 480)
            Divider()
            footer
        }
        .frame(minWidth: 740, minHeight: 560)
        .onAppear {
            didComplete = false
            model.reset()
            model.startMonitoring()
        }
        .onDisappear {
            model.stopMonitoring()
        }
        .onChange(of: model.isUnlocked) { unlocked in
            guard unlocked else { return }
            finishUnlocked()
        }
    }

    private func finishUnlocked() {
        guard !didComplete else { return }
        didComplete = true
        onUnlocked()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Débloquer \(siteName)")
                .font(.headline)
            Text("Validez le challenge anti-bot dans la page ci-dessous. Une fois le catalogue visible, les cookies seront réutilisés pour le scrape.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isUnlocked {
                Label("Site accessible — fermeture…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                Text("En attente du challenge…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Complétez la vérification si elle apparaît.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Annuler") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(didComplete)

            if !model.isUnlocked {
                Button("Continuer quand même") {
                    finishUnlocked()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

@MainActor
final class SiteUnlockModel: ObservableObject {
    @Published var isUnlocked = false
    @Published var isChecking = false

    weak var webView: WKWebView?
    private var pollTask: Task<Void, Never>?

    func reset() {
        isUnlocked = false
        isChecking = true
    }

    func startMonitoring() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshUnlockState()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        webView = nil
    }

    private func refreshUnlockState() async {
        guard let webView else { return }
        let title = webView.title ?? ""
        let html: String
        do {
            let raw = try await webView.evaluateJavaScript(
                "document.documentElement ? document.documentElement.outerHTML : ''"
            )
            html = raw as? String ?? ""
        } catch {
            return
        }

        let unlocked = !BrowserHTMLClient.isCloudflareChallenge(title: title, html: html)
            && BrowserHTMLClient.looksLikeSiteContent(title: title, html: html)
        isChecking = !unlocked
        if unlocked != isUnlocked {
            isUnlocked = unlocked
        }
    }
}

struct UnlockWebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: SiteUnlockModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = HTTPClient.userAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        model.webView = webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: SiteUnlockModel

        init(model: SiteUnlockModel) {
            self.model = model
        }
    }
}
