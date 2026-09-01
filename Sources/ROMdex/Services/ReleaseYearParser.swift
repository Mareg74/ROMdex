import Foundation

enum ReleaseYearParser {
    /// Extraire une année de sortie plausible (1970–2026) depuis un titre, slug ou HTML.
    static func detect(from text: String) -> Int? {
        let patterns = [
            #"\((19[5-9]\d|20[0-2]\d)\)"#,
            #"\[(19[5-9]\d|20[0-2]\d)\]"#,
            #"(?:^|[^\d])(19[5-9]\d|20[0-2]\d)(?:[^\d]|$)"#,
            #"(?:year|released?|sortie|date)[^\d]{0,20}(19[5-9]\d|20[0-2]\d)"#
        ]

        for pattern in patterns {
            if let match = HTMLParser.matches(in: text, pattern: pattern).first,
               let raw = match.groups.first,
               let year = Int(raw),
               (1970 ... 2026).contains(year) {
                return year
            }
        }

        return nil
    }

    static func detect(fromHTML html: String) -> Int? {
        // RomsFun : uniquement le bloc « Release Date » (jamais datePublished / année WP).
        if isLikelyRomsFunPage(html) {
            return romsFunReleaseYear(fromHTML: html)
        }

        // WordPress et pages similaires : champs explicites uniquement, jamais le HTML brut.
        if isLikelyWordPressPage(html) {
            return explicitGameYear(fromHTML: html)
        }

        return explicitGameYear(fromHTML: html)
    }

    /// RomsFun — section « Release Date ». Si plusieurs régions : **EU** en priorité.
    /// Ne lit pas `datePublished` / dates d’article WordPress.
    static func romsFunReleaseYear(fromHTML html: String) -> Int? {
        guard let section = releaseDateSection(from: html) else { return nil }

        // Paires région → année dans le bloc.
        let pairPattern =
            #"(?i)\b(EU|EUR|Europe|PAL|NA|USA|US|North\s*America|JP|JPN|Japan|JA|AU|AUS|Australia|World)\b\s*[:：\-]?\s*([^<\n]{4,60})"#
        var byRegion: [String: Int] = [:]
        for match in HTMLParser.matches(in: section, pattern: pairPattern) {
            let region = match.groups[0].lowercased()
            guard let year = year(fromDateText: match.groups[1]) else { continue }
            // Ignorer une « année » collée à un label Region sans vraie date.
            let key = normalizeRegionKey(region)
            if byRegion[key] == nil {
                byRegion[key] = year
            }
        }

        if let eu = byRegion["eu"] { return eu }
        if let world = byRegion["world"] { return world }
        if let na = byRegion["na"] { return na }
        if let jp = byRegion["jp"] { return jp }
        if let au = byRegion["au"] { return au }

        // Une seule date (ex. « 21 October 1999 ») dans le bloc Release Date.
        if let lone = releaseDateLoneYear(in: section) {
            return lone
        }

        return nil
    }

    // MARK: - Helpers

    /// Champs « Year » / « Release Year » explicites — jamais `datePublished` ni scan générique.
    private static func explicitGameYear(fromHTML html: String) -> Int? {
        let patterns = [
            #"Year:</(?:td|div)>\s*<(?:td|div)[^>]*>\s*(19[5-9]\d|20[0-2]\d)"#,
            #">\s*Release(?:d)? Year\s*:\s*</[^>]+>\s*<[^>]+>\s*(19[5-9]\d|20[0-2]\d)"#,
            #"view-emulator-detail-name">\s*Year:\s*</div>\s*<div class="view-emulator-detail-value">\s*(19[5-9]\d|20[0-2]\d)"#
        ]

        for pattern in patterns {
            if let match = HTMLParser.matches(in: html, pattern: pattern).first,
               let year = Int(match.groups[0]),
               (1970 ... 2026).contains(year) {
                return year
            }
        }

        return nil
    }

    private static func isLikelyWordPressPage(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("wp-content")
            || lower.contains("wordpress")
            || lower.contains("article:published_time")
            || lower.contains("datepublished")
            || lower.contains(#"og:type" content="article"#)
    }

    private static func isLikelyRomsFunPage(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("romsfun.com")
            || lower.contains("romsfun")
            || (lower.contains("release date") && lower.contains("wp-content"))
    }

    private static func releaseDateSection(from html: String) -> String? {
        // Cherche le libellé visible du bloc méta (évite les occurrences trop tôt dans le head).
        let markers = [
            #"(?i)>\s*Release\s*Date\s*<"#,
            #"(?i)Release\s*Date\s*</"#,
            #"(?i)Release\s*Date"#,
            #"(?i)Date\s*de\s*sortie"#
        ]
        for marker in markers {
            guard let regex = try? NSRegularExpression(pattern: marker) else { continue }
            let full = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: full),
                  let start = Range(match.range, in: html) else { continue }
            let from = start.lowerBound
            let end = html.index(from, offsetBy: 1_800, limitedBy: html.endIndex) ?? html.endIndex
            let window = String(html[from ..< end])
            // Doit contenir une année plausible de jeu, pas seulement du markup.
            if releaseDateLoneYear(in: window) != nil
                || HTMLParser.matches(
                    in: window,
                    pattern: #"(?i)\b(EU|NA|JP|USA|Europe|Japan)\b"#
                ).isEmpty == false {
                return window
            }
        }
        return nil
    }

    private static func normalizeRegionKey(_ raw: String) -> String {
        let r = raw.lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        switch r {
        case "eu", "eur", "europe", "pal": return "eu"
        case "na", "usa", "us", "northamerica": return "na"
        case "jp", "jpn", "japan", "ja": return "jp"
        case "au", "aus", "australia": return "au"
        case "world": return "world"
        default: return r
        }
    }

    /// Date isolée typique RomsFun : « 21 October 1999 », « November 19, 1997 ».
    private static func releaseDateLoneYear(in section: String) -> Int? {
        let cleaned = HTMLParser.decodeEntities(section)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)

        let dated = [
            #"(?i)\b\d{1,2}\s+(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+(19[5-9]\d|20[0-2]\d)\b"#,
            #"(?i)\b(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},?\s+(19[5-9]\d|20[0-2]\d)\b"#,
            #"(?i)\b\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(19[5-9]\d|20[0-2]\d)\b"#,
            #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2},?\s+(19[5-9]\d|20[0-2]\d)\b"#
        ]
        for pattern in dated {
            if let match = HTMLParser.matches(in: cleaned, pattern: pattern).first,
               let year = Int(match.groups[0]),
               (1970 ... 2026).contains(year) {
                return year
            }
        }
        return nil
    }

    /// Parse « November 19, 1997 », « 19 November 1997 », « 1997-11-19 ».
    private static func year(fromDateText text: String) -> Int? {
        let cleaned = HTMLParser.decodeEntities(text)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let lone = releaseDateLoneYear(in: cleaned) {
            return lone
        }
        if let match = HTMLParser.matches(in: cleaned, pattern: #"(19[5-9]\d|20[0-2]\d)[-/.]\d{1,2}[-/.]\d{1,2}"#).first,
           let year = Int(match.groups[0]),
           (1970 ... 2026).contains(year) {
            return year
        }
        // Année seule uniquement si le texte ressemble à une date (pas un label « JP »).
        if cleaned.range(of: #"(?i)(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\d{1,2}[-/.]\d{1,2})"#, options: .regularExpression) != nil,
           let match = HTMLParser.matches(in: cleaned, pattern: #"(19[5-9]\d|20[0-2]\d)"#).first,
           let year = Int(match.groups[0]),
           (1970 ... 2026).contains(year) {
            return year
        }
        return nil
    }
}
