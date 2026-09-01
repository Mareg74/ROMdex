import Foundation

enum Platform: String, CaseIterable, Identifiable, Codable, Hashable {
    case gb = "GB"
    case gbc = "GBC"
    case gba = "GBA"
    case nds = "NDS"
    case n3ds = "3DS"
    case nes = "NES"
    case snes = "SNES"
    case n64 = "N64"
    case gameCube = "GC"
    case wii = "WII"
    case wiiU = "WIIU"
    case switchPlatform = "SWITCH"
    case ps1 = "PS1"
    case ps2 = "PS2"
    case ps3 = "PS3"
    case psp = "PSP"
    case xbox = "XBOX"
    case x360 = "X360"
    case dreamcast = "DC"
    case mame = "MAME"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .gba: return "Game Boy Advance"
        case .nds: return "DS"
        case .n3ds: return "3DS"
        case .nes: return "NES"
        case .snes: return "SNES"
        case .n64: return "N64"
        case .gameCube: return "GameCube"
        case .wii: return "Wii"
        case .wiiU: return "Wii U"
        case .switchPlatform: return "Switch"
        case .ps1: return "PlayStation"
        case .ps2: return "PlayStation 2"
        case .ps3: return "PlayStation 3"
        case .psp: return "PSP"
        case .xbox: return "Xbox"
        case .x360: return "Xbox 360"
        case .dreamcast: return "Dreamcast"
        case .mame: return "MAME"
        }
    }

    var vimmSystemID: String? {
        switch self {
        case .gb: return "GB"
        case .gbc: return "GBC"
        case .gba: return "GBA"
        case .nds: return "DS"
        case .n3ds: return "3DS"
        case .nes: return "NES"
        case .snes: return "SNES"
        case .n64: return "N64"
        case .gameCube: return "GameCube"
        case .wii: return "Wii"
        case .wiiU: return "WiiU"
        case .switchPlatform: return nil
        case .ps1: return "PS1"
        case .ps2: return "PS2"
        case .ps3: return nil // Pas de listing PS3 sur Vimm
        case .psp: return "PSP"
        case .xbox: return "Xbox"
        case .x360: return "Xbox360"
        case .dreamcast: return "Dreamcast"
        case .mame: return nil
        }
    }

    var retrosticSlug: String? {
        switch self {
        case .gb: return "gb"
        case .gbc: return "gbc"
        case .gba: return "gba"
        case .nds: return "nds"
        case .n3ds: return "3ds"
        case .nes: return "nes"
        case .snes: return "snes"
        case .n64: return "n64"
        case .gameCube: return "gamecube"
        case .wii: return "wii"
        case .wiiU: return "wii-u"
        case .switchPlatform: return "switch"
        case .ps1: return "psx"
        case .ps2: return "ps2"
        case .ps3: return "ps3"
        case .psp: return "psp"
        case .xbox: return "xbox"
        case .x360: return nil // Pas de listing Xbox 360 fiable sur Retrostic
        case .dreamcast: return "dreamcast"
        case .mame: return "mame"
        }
    }

    /// Catégories / sections CDRomance (recherche + catalogue REST).
    /// Limité aux types WordPress réellement exposés par l’API (`/wp-json/wp/v2/types`).
    var cdRomanceCategory: String? {
        cdRomancePostType != nil ? cdRomanceCategorySlug : nil
    }

    private var cdRomanceCategorySlug: String? {
        switch self {
        case .nds: return "nintendo-ds"
        case .gba: return "gameboy-advance"
        case .gb: return "gameboy"
        case .gbc: return "gameboy-color"
        case .nes: return "nes"
        case .snes: return "snes"
        case .n64: return "nintendo-64"
        case .gameCube: return "gamecube"
        case .wii: return "wii"
        case .ps1: return "psx"
        case .ps2: return "ps2"
        case .psp: return "psp"
        case .dreamcast: return "dreamcast"
        default: return nil
        }
    }

    /// Type de contenu WordPress CDRomance (`/wp-json/wp/v2/{type}`).
    var cdRomancePostType: String? {
        switch self {
        case .gb: return "gb_roms"
        case .gbc: return "gbc_roms"
        case .gba: return "gba-roms"
        case .nds: return "nds-roms"
        case .nes: return "nes-roms"
        case .snes: return "snes-rom"
        case .n64: return "n64-roms"
        case .gameCube: return "gcn-iso"
        case .wii: return "wii-iso"
        case .ps1: return "psx-iso"
        case .ps2: return "ps2-iso"
        case .psp: return "psp"
        case .dreamcast: return "dc-iso"
        default: return nil
        }
    }

    /// Racines de listing The Old Computer (`/roms/index.php?folder=`).
    /// Nintendo est fermé aux invités (DMCA) — non scrapable sans compte.
    var oldComputerBrowseRoots: [String]? {
        switch self {
        case .ps1: return ["Sony/Playstation-PSX-PS1"]
        case .ps2: return ["Sony/Playstation-2"]
        case .ps3: return ["Sony/Playstation-3"]
        case .psp: return ["Sony/Playstation-Portable"]
        case .xbox: return ["Microsoft/Xbox"]
        case .x360: return ["Microsoft/Xbox-360"]
        case .dreamcast: return ["Sega/Dreamcast"]
        case .mame: return ["MAME"]
        default: return nil
        }
    }

    var oldComputerFolder: String? {
        oldComputerBrowseRoots?.first
    }

    var mondemulID: String? {
        switch self {
        case .nds: return "26"
        case .n3ds: return "47"
        case .gba: return "12"
        case .gb: return "10"
        case .gbc: return "11"
        case .nes: return "7"
        case .snes: return "8"
        case .n64: return "9"
        case .gameCube: return "21"
        case .wii: return "36"
        case .wiiU: return "48"
        case .switchPlatform: return "49"
        case .ps1: return "15"
        case .ps2: return "22"
        case .ps3: return nil
        case .psp: return "31"
        case .xbox: return "23"
        case .x360: return "37"
        case .dreamcast: return "20"
        case .mame: return "1"
        }
    }
}
