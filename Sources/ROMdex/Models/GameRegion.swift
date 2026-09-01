import Foundation
import SwiftUI

enum GameRegion: String, CaseIterable, Identifiable, Codable, Hashable {
    case us
    case eu
    case france
    case ja
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: return "US"
        case .eu: return "EU"
        case .france: return "FR"
        case .ja: return "JA"
        case .other: return "Autres"
        }
    }

    var fullName: String {
        switch self {
        case .us: return "Amérique (US)"
        case .eu: return "Europe (EU)"
        case .france: return "France (FR)"
        case .ja: return "Japon (JA)"
        case .other: return "Autres régions"
        }
    }

    var flagEmoji: String {
        switch self {
        case .us: return "🇺🇸"
        case .eu: return "🇪🇺"
        case .france: return "🇫🇷"
        case .ja: return "🇯🇵"
        case .other: return "🌐"
        }
    }

    var badgeColor: Color {
        switch self {
        case .us: return Color(red: 0.15, green: 0.35, blue: 0.70)
        case .eu: return Color(red: 0.10, green: 0.30, blue: 0.65)
        case .france: return Color(red: 0.10, green: 0.25, blue: 0.55)
        case .ja: return Color(red: 0.75, green: 0.15, blue: 0.20)
        case .other: return Color(red: 0.40, green: 0.40, blue: 0.45)
        }
    }

    /// `[T-German]`, `(T-Eng)` = langue de traduction, pas la région du dump.
    static func strippingTranslationTags(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[T[+\-][^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\(T[+\-][^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[t[+\-][^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\(t[+\-][^)]*\)"#, with: " ", options: .regularExpression)
    }

    static func titleLooksTranslated(_ title: String) -> Bool {
        title.range(of: #"\[T[+\-]"#, options: [.regularExpression, .caseInsensitive]) != nil
            || title.range(of: #"\(T[+\-]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Déduit la région à partir d’un titre, d’un slug ou d’un libellé de drapeau.
    static func detect(from text: String) -> GameRegion {
        let cleaned = strippingTranslationTags(text)
        let normalized = " \(cleaned.lowercased()) "
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let usMarkers = [
            " usa ", " (usa) ", " [usa] ", " us ", " (us) ", " [us] ",
            " (u) ", " (u). ", " (u)[", " (u)(",
            " america ", " ntsc u ", " united states ", " /us ",
            " flags/us ", " flags/usa ",
            " flags-usa ", "flags-usa",
            "usa.png", "usa.svg", "us.svg", "us.png"
        ]

        // France avant EU.
        let franceMarkers = [
            " france ", " (france) ", " [france] ",
            " fr ", " (fr) ", " [fr] ", " /fr ",
            " (f) ", " (f). ", " (f).zip ", " (f).7z ",
            " flags/fr ", "fr.svg", "fr.png",
            " flags-france ", "flags-france", " flags-fr ", "flags-fr"
            // pas "french" : trop souvent une traduction
        ]

        let jaMarkers = [
            " japan ", " (japan) ", " [japan] ", " jap ", " (jap) ",
            " jp ", " (jp) ", " [jp] ", " ja ", " (ja) ", " jpn ",
            " (j) ", " (j). ", " (j)[", " ntsc j ", " /jp ",
            " japan.png ", " japan.svg ",
            " flags/jp ", " flags/ja ", " flags/jpn ",
            " flags-japan ", "flags-japan", " flags-jp ", "flags-jp"
        ]

        // Pas de "german" : `[T-German]` = traduction, pas région DE.
        // `(UE)` = USA/Europe → EU (code ROM classique).
        let euMarkers = [
            " europe ", " (europe) ", " [europe] ", " eu ", " (eu) ", " [eu] ",
            " eur ", " (eur) ", " pal ", " (pal) ", " ue ", " (ue) ", " (ue). ",
            " germany ", " deutschland ", " spain ", " italy ", " uk ",
            " united kingdom ", " australia ", " (a) ", " (e) ", " (e). ", " (g) ", " (g)(",
            " de ", " (de) ", " [de] ", " /de ",
            " /eu ", " europe.png ", " europe.svg ",
            " flags/eu ", " flags/eur ", " flags/de ", " flags/es ", " flags/it ", " flags/gb ",
            " flags-europe ", "flags-europe", " flags-eu ", "flags-eu",
            "de.svg", "de.png"
        ]

        if usMarkers.contains(where: { normalized.contains($0) }) {
            return .us
        }

        if franceMarkers.contains(where: { normalized.contains($0) }) {
            return .france
        }

        if jaMarkers.contains(where: { normalized.contains($0) }) {
            return .ja
        }

        if euMarkers.contains(where: { normalized.contains($0) }) {
            return .eu
        }

        if normalized.contains(" world ")
            || normalized.contains("(world)")
            || normalized.contains(" korea ")
            || normalized.contains("flags-korea")
            || normalized.contains(" china ")
            || normalized.contains(" brazil ")
            || normalized.contains(" asia ") {
            return .other
        }

        return .other
    }

    /// Codes courts issus des pages détail (gameLocation, Region, etc.).
    static func fromShortCode(_ raw: String) -> GameRegion? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "US", "USA", "U", "NTSC-U", "NTSCU": return .us
        case "FR", "FRA", "F", "FRANCE": return .france
        case "EU", "EUR", "PAL", "E", "EUROPE",
             "DE", "GER", "DEU", "G", "GERMANY": return .eu
        case "JP", "JA", "JPN", "J", "JAPAN", "NTSC-J", "NTSCJ": return .ja
        default: return nil
        }
    }

    static func detect(fromTitle title: String, hint: String? = nil) -> GameRegion {
        if let hint, !hint.isEmpty {
            let cleanedHint = strippingTranslationTags(hint)
            let fromHint = detect(from: cleanedHint)
            if fromHint != .other || hintContainsExplicitOther(cleanedHint) {
                return fromHint
            }
            if let code = fromShortCode(cleanedHint) {
                return code
            }
        }
        return detect(from: title)
    }

    private static func hintContainsExplicitOther(_ hint: String) -> Bool {
        let n = hint.lowercased()
        return n.contains("world") || n.contains("korea") || n.contains("china") || n.contains("asia") || n.contains("brazil")
    }
}
