import AppKit
import Foundation
import WebKit

/// Verrouille la navigation d’un aperçu au domaine de base de l’URL d’origine
/// (ex. `nxbrew.net` et sous-domaines), bloque les popups et masque les overlays cookies.
@MainActor
final class DomainLockedWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost.lowercased()
        super.init()
    }

    static func baseHost(from url: URL) -> String {
        (url.host ?? "").lowercased()
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let script = WKUserScript(
            source: Self.overlayCleanupScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)
        return config
    }

    func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            return true
        }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == allowedHost || host.hasSuffix("." + allowedHost)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url ?? navigationAction.request.mainDocumentURL

        // Nouvel onglet / frame externe hors domaine → bloqué.
        if navigationAction.targetFrame == nil, !isAllowed(url) {
            decisionHandler(.cancel)
            return
        }

        if isAllowed(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if isAllowed(navigationResponse.response.url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Pas de popup : si même domaine, charger dans la même vue.
        if let url = navigationAction.request.url, isAllowed(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {}

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Retire bannières cookies / overlays plein écran fréquents sur les sites ROM.
    private static let overlayCleanupScript = """
    (function () {
      if (window.__romdexOverlayGuard) return;
      window.__romdexOverlayGuard = true;

      function looksLikeOverlay(el) {
        try {
          var s = getComputedStyle(el);
          if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
          var z = parseInt(s.zIndex, 10);
          if (!(s.position === 'fixed' || s.position === 'sticky') || !(z > 100)) return false;
          var r = el.getBoundingClientRect();
          return r.width > window.innerWidth * 0.45 && r.height > window.innerHeight * 0.35;
        } catch (e) { return false; }
      }

      function hide() {
        var nodes = document.querySelectorAll(
          '[id*="cookie"],[id*="Cookie"],[class*="cookie"],[class*="Cookie"],' +
          '[id*="consent"],[id*="Consent"],[class*="consent"],[class*="Consent"],' +
          '[class*="fc-consent"],[id*="sp_message"],[class*="qc-cmp"],[class*="didomi"],' +
          '[class*="ogury"],[id*="onetrust"],[class*="onetrust"],[class*="cmp-"],' +
          '[class*="popup"],[class*="Popup"],[class*="modal"],[class*="Modal"],' +
          '[id*="overlay"],[id*="Overlay"],[class*="overlay"],[class*="Overlay"]'
        );
        nodes.forEach(function (el) {
          try { el.remove(); } catch (e) {}
        });

        document.querySelectorAll('div,aside,section,iframe').forEach(function (el) {
          if (looksLikeOverlay(el)) {
            try { el.remove(); } catch (e) {}
          }
        });

        document.documentElement.style.overflow = 'auto';
        document.body && (document.body.style.overflow = 'auto');
      }

      hide();
      new MutationObserver(hide).observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(hide, 400);
      setTimeout(hide, 1200);
    })();
    """
}
