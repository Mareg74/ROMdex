import Foundation

enum CoverArtParser {
    /// Retire les suffixes WordPress de taille (`-520x292`, `-150x150`, …) pour viser l’original.
    /// Les variantes « boxstyle » / « alx » NXBrew sont souvent des crops paysage ; l’original est portrait.
    static func preferOriginalURL(_ url: URL) -> URL {
        let name = url.lastPathComponent
        guard let match = name.range(
            of: #"-\d{2,4}x\d{2,4}(?=\.[A-Za-z0-9]+$)"#,
            options: .regularExpression
        ) else {
            return url
        }
        var stripped = name
        stripped.removeSubrange(match)
        return url.deletingLastPathComponent().appendingPathComponent(stripped)
    }

    /// Candidats de chargement : original d’abord, puis URL stockée (si l’original 404).
    static func loadCandidates(for url: URL) -> [URL] {
        let original = preferOriginalURL(url)
        if original == url { return [url] }
        return [original, url]
    }

    /// Screenshot « title » (ou premier shot) depuis une fiche RomHustler.
    static func romHustlerCover(fromHTML html: String) -> URL? {
        let absoluteTitle = #"(https://romhustler\.org/img/screenshots/[^"'\s]+/title/[^"'\s]+)"#
        if let match = HTMLParser.matches(in: html, pattern: absoluteTitle).first,
           let cover = URL(string: match.groups[0]) {
            return cover
        }

        let relativeTitle = #"((?:https://romhustler\.org)?/img/screenshots/[^"'\s]+/title/[^"'\s]+)"#
        if let match = HTMLParser.matches(in: html, pattern: relativeTitle).first,
           let cover = HTTPClient.absoluteURL(match.groups[0], base: URL(string: "https://romhustler.org")!) {
            return cover
        }

        let jsonShot = #""screenshot"\s*:\s*"(https://romhustler\.org/[^"]+)""#
        if let match = HTMLParser.matches(in: html, pattern: jsonShot).first,
           let cover = URL(string: match.groups[0]) {
            return cover
        }

        // img-responsive title / premier screenshot.
        let imgTag = #"<img[^>]+src="((?:https://romhustler\.org)?/img/screenshots/[^"]+)"[^>]*>"#
        if let match = HTMLParser.matches(in: html, pattern: imgTag).first,
           let cover = HTTPClient.absoluteURL(match.groups[0], base: URL(string: "https://romhustler.org")!) {
            return cover
        }

        let anyShot = #"(https://romhustler\.org/img/screenshots/[^"'\s]+\.(?:png|jpg|jpeg|webp))"#
        if let match = HTMLParser.matches(in: html, pattern: anyShot).first,
           let cover = URL(string: match.groups[0]) {
            return cover
        }

        return nil
    }

    /// Associe un chemin de page (`/roms/...`) à une URL d’image trouvée à proximité dans le HTML.
    /// - Important : `pathPattern` ne doit **pas** contenir de groupes capturants (utiliser `(?:…)`).
    static func thumbnails(
        in html: String,
        pathPattern: String,
        imagePattern: String,
        baseURL: URL
    ) -> [String: URL] {
        var map: [String: URL] = [:]

        // `href` peut être absolu (`https://host/roms/...`) ou relatif (`/roms/...`).
        let hrefCapture = "(?:https?://[^\"/]+)?(" + pathPattern + ")"

        let insidePattern =
            "<a[^>]+href=\"" + hrefCapture + "\"[^>]*>[\\s\\S]{0,2500}?(?:src|data-src|data-lazy-src|data-original|srcset)=\""
            + "(" + imagePattern + ")\""
        for match in HTMLParser.matches(in: html, pattern: insidePattern) {
            absorb(path: match.groups[0], image: match.groups[1], baseURL: baseURL, into: &map)
        }

        let beforePattern =
            "(?:src|data-src|data-lazy-src|data-original|srcset)=\"" + "(" + imagePattern + ")"
            + "\"[\\s\\S]{0,1200}?<a[^>]+href=\"" + hrefCapture + "\""
        for match in HTMLParser.matches(in: html, pattern: beforePattern) {
            absorb(path: match.groups[1], image: match.groups[0], baseURL: baseURL, into: &map)
        }

        // Cartes où l’image est hors du `<a>` (lazy-load WP fréquent).
        merge(proximityThumbnails(in: html, pathPattern: pathPattern, imagePattern: imagePattern, baseURL: baseURL), into: &map)

        return map
    }

    /// Pour chaque lien jeu, cherche une image dans une fenêtre autour du `href`.
    static func proximityThumbnails(
        in html: String,
        pathPattern: String,
        imagePattern: String,
        baseURL: URL,
        windowBefore: Int = 2200,
        windowAfter: Int = 900
    ) -> [String: URL] {
        var map: [String: URL] = [:]
        let hrefPattern = "(?:https?://[^\"/]+)?(" + pathPattern + ")"
        guard let regex = try? NSRegularExpression(pattern: hrefPattern, options: [.caseInsensitive]) else {
            return [:]
        }
        let full = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, options: [], range: full) {
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let fullRange = Range(match.range, in: html) else { continue }
            let path = String(html[pathRange])
            let start = html.index(fullRange.lowerBound, offsetBy: -windowBefore, limitedBy: html.startIndex) ?? html.startIndex
            let end = html.index(fullRange.upperBound, offsetBy: windowAfter, limitedBy: html.endIndex) ?? html.endIndex
            let window = String(html[start ..< end])
            for imgMatch in HTMLParser.matches(in: window, pattern: "(" + imagePattern + ")") {
                absorb(path: path, image: imgMatch.groups[0], baseURL: baseURL, into: &map)
            }
        }
        return map
    }

    /// Jacquette fiche RomsFun (`og:image` ou image featured WP).
    static func romsFunCover(fromHTML html: String) -> URL? {
        let base = URL(string: "https://romsfun.com")!
        let patterns = [
            #"(?:property|name)="og:image"[^>]*content="(https://romsfun\.com/wp-content/uploads/[^"]+)""#,
            #"content="(https://romsfun\.com/wp-content/uploads/[^"]+)"[^>]*(?:property|name)="og:image""#,
            #""image"\s*:\s*"(https://romsfun\.com/wp-content/uploads/[^"]+)""#,
            #"<meta[^>]+property="og:image:secure_url"[^>]+content="(https://romsfun\.com/wp-content/uploads/[^"]+)""#,
            #"<img[^>]+class="[^"]*(?:wp-post-image|attachment-post-thumbnail|size-full|size-large)[^"]*"[^>]+(?:src|data-src|data-lazy-src|data-original)="((?:https://romsfun\.com)?/wp-content/uploads/[^"'\s]+)""#,
            #"<img[^>]+(?:src|data-src|data-lazy-src|data-original)="((?:https://romsfun\.com)?/wp-content/uploads/[^"'\s]+\.(?:png|jpe?g|webp))"[^>]*class="[^"]*(?:wp-post-image|attachment)[^"]*""#,
            // Markup type Animastar : <img … src="…/Animastar-GB.jpg"> juste avant le H1
            #"<img[^>]+(?:src|data-src|data-lazy-src)="((?:https://romsfun\.com)?/wp-content/uploads/[^"'\s]+\.(?:png|jpe?g|webp))"[^>]*>\s*(?:</a>\s*)?<h1"#
        ]
        for pattern in patterns {
            if let match = HTMLParser.matches(in: html, pattern: pattern).first,
               let url = HTTPClient.absoluteURL(match.groups[0], base: base),
               !isLikelyJunkCover(url) {
                return preferOriginalURL(url)
            }
        }

        // srcset : prendre la plus grande candidate.
        let srcsetPat = #"(?:srcset|data-srcset)="([^"]*wp-content/uploads[^"]+)""#
        for match in HTMLParser.matches(in: html, pattern: srcsetPat) {
            if let url = bestSrcsetURL(match.groups[0], base: base), !isLikelyJunkCover(url) {
                return preferOriginalURL(url)
            }
        }

        // Premier upload « jeu » dans le corps (évite logos / icônes console).
        let anyUpload = #"(?:src|data-src|data-lazy-src|data-original)="((?:https://romsfun\.com)?/wp-content/uploads/[^"'\s]+\.(?:png|jpe?g|webp))""#
        for match in HTMLParser.matches(in: html, pattern: anyUpload) {
            guard let url = HTTPClient.absoluteURL(match.groups[0], base: base),
                  !isLikelyJunkCover(url) else { continue }
            return preferOriginalURL(url)
        }
        return nil
    }

    /// Script JS pour extraire la jaquette une fois le DOM chargé (lazy-load inclus).
    static var romsFunCoverJavaScript: String {
        """
        (function () {
          function ok(u) {
            if (!u || u.indexOf('wp-content/uploads') < 0) return false;
            var l = u.toLowerCase();
            if (l.indexOf('logo') >= 0 || l.indexOf('icon') >= 0 || l.indexOf('banner') >= 0) return false;
            if (l.indexOf('console') >= 0 || l.indexOf('icons8') >= 0) return false;
            if (l.indexOf('/emoji') >= 0 || l.indexOf('1x1') >= 0) return false;
            return /\\.(png|jpe?g|webp)(\\?|$)/i.test(u);
          }
          function abs(u) {
            try { return new URL(u, location.href).href; } catch (e) { return null; }
          }
          var og = document.querySelector('meta[property="og:image"], meta[name="og:image"]');
          if (og && ok(og.content)) return abs(og.content);
          var nodes = document.querySelectorAll(
            'img.wp-post-image, img.attachment-post-thumbnail, article img, .entry-content img, .post-thumbnail img, main img'
          );
          for (var i = 0; i < nodes.length; i++) {
            var img = nodes[i];
            var cand = img.currentSrc || img.src || img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('data-original');
            if (ok(cand)) return abs(cand);
            var ss = img.getAttribute('srcset') || img.getAttribute('data-srcset');
            if (ss) {
              var parts = ss.split(',').map(function (p) { return p.trim().split(/\\s+/)[0]; });
              for (var j = parts.length - 1; j >= 0; j--) {
                if (ok(parts[j])) return abs(parts[j]);
              }
            }
          }
          return null;
        })();
        """
    }

    /// Script JS : carte `pathname` → URL jaquette sur une page listing RomsFun (lazy-load inclus).
    static var romsFunListingThumbsJavaScript: String {
        """
        (function () {
          function ok(u) {
            if (!u || u.indexOf('wp-content/uploads') < 0) return false;
            var l = u.toLowerCase();
            if (l.indexOf('logo') >= 0 || l.indexOf('icon') >= 0 || l.indexOf('banner') >= 0) return false;
            if (l.indexOf('console') >= 0 || l.indexOf('icons8') >= 0) return false;
            if (l.indexOf('/emoji') >= 0 || l.indexOf('1x1') >= 0) return false;
            return /\\.(png|jpe?g|webp)(\\?|$)/i.test(u);
          }
          function abs(u) {
            try { return new URL(u, location.href).href; } catch (e) { return null; }
          }
          function imgURL(img) {
            var cand = img.currentSrc || img.src || img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('data-original');
            if (ok(cand)) return abs(cand);
            var ss = img.getAttribute('srcset') || img.getAttribute('data-srcset');
            if (ss) {
              var parts = ss.split(',').map(function (p) { return p.trim().split(/\\s+/)[0]; });
              for (var j = parts.length - 1; j >= 0; j--) {
                if (ok(parts[j])) return abs(parts[j]);
              }
            }
            return null;
          }
          var map = {};
          var links = document.querySelectorAll('a[href*="/roms/"][href$=".html"]');
          for (var i = 0; i < links.length; i++) {
            var a = links[i];
            var href = a.getAttribute('href');
            if (!href || href.indexOf('/page/') >= 0) continue;
            var path;
            try { path = new URL(href, location.href).pathname; } catch (e) { continue; }
            if (map[path]) continue;
            var root = a.closest('article, li, .post, .game-card, .rom, .card, .entry') || a.parentElement;
            if (!root) continue;
            var imgs = root.querySelectorAll('img');
            for (var k = 0; k < imgs.length; k++) {
              var u = imgURL(imgs[k]);
              if (u) { map[path] = u; break; }
            }
          }
          return JSON.stringify(map);
        })();
        """
    }

    private static func bestSrcsetURL(_ srcset: String, base: URL) -> URL? {
        let parts = srcset.split(separator: ",")
        var best: (url: URL, width: Int)?
        for part in parts {
            let bits = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard let first = bits.first,
                  let url = HTTPClient.absoluteURL(String(first), base: base) else { continue }
            var width = 0
            if bits.count > 1, let w = Int(bits[1].replacingOccurrences(of: "w", with: "")) {
                width = w
            }
            if best == nil || width >= best!.width {
                best = (url, width)
            }
        }
        return best?.url
    }

    private static func merge(_ extra: [String: URL], into map: inout [String: URL]) {
        for (path, url) in extra {
            map[path] = preferCover(existing: map[path], candidate: url)
        }
    }

    private static func absorb(path: String, image: String, baseURL: URL, into map: inout [String: URL]) {
        let cleaned = image
            .components(separatedBy: " ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? image

        let lower = cleaned.lowercased()
        guard !lower.contains("spinner"),
              !lower.contains("logo"),
              !lower.contains("no-image"),
              !lower.contains("data:image"),
              !lower.contains("flags/") else { return }

        guard let url = HTTPClient.absoluteURL(cleaned, base: baseURL) else { return }
        if url.path.lowercased().contains("1x1") { return }
        if isLikelyJunkCover(url) { return }

        let pathKey: String
        if let absolute = URL(string: path), absolute.host != nil {
            pathKey = absolute.path
        } else {
            pathKey = path
        }

        map[pathKey] = preferCover(existing: map[pathKey], candidate: url)
    }

    /// Logos site / badges console / placeholders listing — ne pas traiter comme jaquette.
    static func isLikelyJunkCover(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let path = url.path.lowercased()

        if name.contains("logo") || name.contains("banner") || name.contains("avatar")
            || name.contains("sprite") || name.contains("icons8") {
            return true
        }
        // Placeholders listing RomsFun (Xbox 360, GBA, Wii U, …).
        if name.contains("console") || name.hasPrefix("console_") || name.contains("-console-") {
            return true
        }
        if path.contains("/emoji") || name.contains("1x1") || name.contains("spacer") {
            return true
        }
        // Badges console courts : game-boy-color.png, nintendo-64.png, …
        let badgeNames = [
            "game-boy.png", "game-boy-color.png", "game-boy-advance.png", "gba.png", "gbc.png",
            "gamecube.png", "nintendo-64.png", "nintendo-ds.png", "nintendo-3ds.png",
            "nintendo-wii.png", "wii-u.png", "wii.png", "nes.png", "snes.png", "n64.png",
            "playstation.png", "playstation-2.png", "psp.png", "psp-icon", "xbox.png", "xbox-360.png",
            "dreamcast.png", "sega-dreamcast.png", "ps1-300x299.png", "ps2-game.jpg"
        ]
        if badgeNames.contains(where: { name == $0 || name.hasPrefix($0.replacingOccurrences(of: ".png", with: "")) && name.contains("icon") }) {
            return true
        }
        if name.hasSuffix("-icon.png") || name.hasSuffix("_icon.png") || name.hasSuffix("-logo.png") {
            return true
        }
        // Icône plateformegénérique type « Nintendo-DS-300x300.jpg » sans titre de jeu.
        let platformOnly = [
            "nintendo-ds", "nintendo-3ds", "nintendo-wii", "nintendo-64", "game-boy",
            "xbox-360", "playstation", "super-nintendo"
        ]
        if platformOnly.contains(where: { name == "\($0).png" || name == "\($0).jpg" || name.hasPrefix("\($0)-300x") }) {
            return true
        }
        return false
    }

    /// `true` si l’URL peut servir de jaquette (non nil, non placeholder).
    static func isUsableCover(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !isLikelyJunkCover(url)
    }

    private static func preferCover(existing: URL?, candidate: URL) -> URL {
        guard let existing else { return candidate }
        return score(candidate) >= score(existing) ? candidate : existing
    }

    private static func score(_ url: URL) -> Int {
        let s = url.absoluteString.lowercased()
        if s.contains("front-cover") || s.contains("boxart") { return 4 }
        if s.contains("cover") { return 3 }
        if s.contains("box") { return 2 }
        if s.contains("thumb") || s.contains("screenshot") { return 1 }
        // Préférer les jaquettes portrait WP (-300x400) aux icônes.
        if s.contains("300x400") || s.contains("400x") { return 2 }
        return 0
    }
}
