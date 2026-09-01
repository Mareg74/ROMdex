import Foundation

/// Normalise et extrait le genre / type de jeu depuis tags, sujets ou HTML.
enum GenreParser {
    private static let noise: Set<String> = [
        "eshop", "nsp", "xci", "nsz", "nsw", "switch", "rom", "iso", "game", "games",
        "update", "dlc", "firmware", "base", "other", "misc", "various", "unknown",
        "nintendo", "sony", "microsoft", "sega"
    ]

    private static let frenchLabels: [String: String] = [
        "action": "Action",
        "adventure": "Aventure",
        "rpg": "RPG",
        "role-playing": "RPG",
        "role playing": "RPG",
        "racing": "Course",
        "race": "Course",
        "driving": "Course",
        "sports": "Sport",
        "sport": "Sport",
        "fighting": "Combat",
        "fighter": "Combat",
        "shooter": "Tir",
        "fps": "Tir",
        "platformer": "Plateforme",
        "platform": "Plateforme",
        "puzzle": "Puzzle",
        "simulation": "Simulation",
        "sim": "Simulation",
        "strategy": "Stratégie",
        "arcade": "Arcade",
        "horror": "Horreur",
        "music": "Musique",
        "rhythm": "Rythme",
        "party": "Party",
        "board": "Plateau",
        "card": "Cartes",
        "educational": "Éducatif",
        "visual novel": "Visual novel",
        "shoot 'em up": "Shoot'em up",
        "shmup": "Shoot'em up",
        "beat 'em up": "Beat'em up",
        "stealth": "Infiltration",
        "survival": "Survie",
        "sandbox": "Sandbox",
        "open world": "Monde ouvert"
    ]

    /// Affichage FR quand possible, sinon libellé nettoyé.
    static func displayName(for raw: String) -> String {
        let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = frenchLabels[key] { return mapped }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ raw: String) -> String? {
        let text = HTMLParser.decodeEntities(raw)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"&[^;]+;"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }

        // Plusieurs genres séparés → on garde les 2 premiers utiles.
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: ",/;|·•"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isUseful($0) }

        guard !parts.isEmpty else { return nil }

        let labeled = parts.prefix(2).map { displayName(for: $0) }
        return labeled.joined(separator: " · ")
    }

    static func fromTags(_ tags: [String]) -> String? {
        let cleaned = tags.compactMap { tag -> String? in
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUseful(t) else { return nil }
            return displayName(for: t)
        }
        guard !cleaned.isEmpty else { return nil }
        // Déduplique en gardant l’ordre.
        var seen = Set<String>()
        var unique: [String] = []
        for item in cleaned {
            if seen.insert(item.lowercased()).inserted {
                unique.append(item)
            }
        }
        return unique.prefix(2).joined(separator: " · ")
    }

    static func fromSubjects(_ subjects: [String]) -> String? {
        fromTags(subjects)
    }

    static func detect(fromHTML html: String) -> String? {
        let patterns = [
            #"Genre:</td>\s*<td[^>]*>\s*([^<]+?)\s*</td>"#,
            #"Genre:</th>\s*<td[^>]*>\s*([^<]+?)\s*</td>"#,
            #"Genre:\s*</div>\s*<div[^>]*>\s*([^<]+?)\s*</div>"#,
            #"view-emulator-detail-name">\s*Genre:\s*</div>\s*<div class="view-emulator-detail-value">\s*([^<]+?)\s*</div>"#,
            #"<span[^>]*>\s*Genre\s*:?\s*</span>\s*<span[^>]*>\s*([^<]+?)\s*</span>"#,
            #"itemprop="genre"[^>]*content="([^"]+)""#,
            #"itemprop="genre"[^>]*>\s*([^<]+?)\s*<"#,
            #"<meta[^>]+property="og:video:tag"[^>]+content="([^"]+)""#,
            #">\s*Genre\s*:\s*([^<\n]{2,60})\s*<"#
        ]

        for pattern in patterns {
            if let raw = HTMLParser.matches(in: html, pattern: pattern).first?.groups.first,
               let genre = normalize(raw) {
                return genre
            }
        }
        return nil
    }

    private static func isUseful(_ raw: String) -> Bool {
        let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 2, key.count <= 40 else { return false }
        if noise.contains(key) { return false }
        if key.hasPrefix("http") { return false }
        if key.allSatisfy({ $0.isNumber }) { return false }
        return true
    }
}
