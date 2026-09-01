import SwiftUI

extension Platform {
    var brandColor: Color {
        switch self {
        case .gb: return Color(red: 0.45, green: 0.55, blue: 0.18)
        case .gbc: return Color(red: 0.55, green: 0.35, blue: 0.75)
        case .gba: return Color(red: 0.35, green: 0.45, blue: 0.75)
        case .nds: return Color(red: 0.20, green: 0.35, blue: 0.65)
        case .n3ds: return Color(red: 0.75, green: 0.15, blue: 0.20)
        case .nes: return Color(red: 0.70, green: 0.15, blue: 0.18)
        case .snes: return Color(red: 0.55, green: 0.30, blue: 0.65)
        case .n64: return Color(red: 0.15, green: 0.55, blue: 0.35)
        case .gameCube: return Color(red: 0.45, green: 0.25, blue: 0.70)
        case .wii: return Color(red: 0.20, green: 0.55, blue: 0.85)
        case .wiiU: return Color(red: 0.10, green: 0.45, blue: 0.75)
        case .switchPlatform: return Color(red: 0.90, green: 0.15, blue: 0.25)
        case .ps1: return Color(red: 0.20, green: 0.30, blue: 0.70)
        case .ps2: return Color(red: 0.10, green: 0.25, blue: 0.55)
        case .ps3: return Color(red: 0.05, green: 0.15, blue: 0.40)
        case .psp: return Color(red: 0.15, green: 0.20, blue: 0.35)
        case .xbox: return Color(red: 0.20, green: 0.55, blue: 0.15)
        case .x360: return Color(red: 0.45, green: 0.70, blue: 0.15)
        case .dreamcast: return Color(red: 0.85, green: 0.45, blue: 0.15)
        case .mame: return Color(red: 0.85, green: 0.20, blue: 0.20)
        }
    }

    var logoMark: String {
        switch self {
        case .gb: return "GB"
        case .gbc: return "GBC"
        case .gba: return "GBA"
        case .nds: return "DS"
        case .n3ds: return "3DS"
        case .nes: return "NES"
        case .snes: return "SNES"
        case .n64: return "N64"
        case .gameCube: return "GC"
        case .wii: return "Wii"
        case .wiiU: return "WiiU"
        case .switchPlatform: return "SW"
        case .ps1: return "PS1"
        case .ps2: return "PS2"
        case .ps3: return "PS3"
        case .psp: return "PSP"
        case .xbox: return "XB"
        case .x360: return "360"
        case .dreamcast: return "DC"
        case .mame: return "♪"
        }
    }
}

enum PlatformLabelSize {
    case compact
    case regular
    case large

    var iconSide: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 28
        case .large: return 36
        }
    }

    var nameFont: Font {
        switch self {
        case .compact: return .subheadline.weight(.semibold)
        case .regular: return .title3.weight(.semibold)
        case .large: return .title2.weight(.bold)
        }
    }

    var markFontSize: CGFloat {
        switch self {
        case .compact: return 8
        case .regular: return 10
        case .large: return 12
        }
    }
}

struct PlatformIcon: View {
    let platform: Platform
    var size: PlatformLabelSize = .regular

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.iconSide * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            platform.brandColor,
                            platform.brandColor.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size.iconSide * 0.22, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }

            PlatformGlyph(platform: platform)
                .frame(width: size.iconSide * 0.55, height: size.iconSide * 0.55)
                .opacity(0.22)

            Text(platform.logoMark)
                .font(.system(size: size.markFontSize, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: size.iconSide, height: size.iconSide)
        .shadow(color: platform.brandColor.opacity(0.35), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

/// Silhouettes stylisées (pas de logos officiels) pour distinguer les consoles.
struct PlatformGlyph: View {
    let platform: Platform

    var body: some View {
        Group {
            switch platform {
            case .n64:
                Image(systemName: "cube.fill")
            case .gameCube:
                Image(systemName: "diamond.fill")
            case .wii, .wiiU:
                Image(systemName: "w.circle.fill")
            case .switchPlatform:
                Image(systemName: "rectangle.split.2x1.fill")
            case .nds, .n3ds:
                Image(systemName: "rectangle.split.1x2.fill")
            case .gb, .gbc, .gba:
                Image(systemName: "ipad")
            case .nes, .snes:
                Image(systemName: "rectangle.portrait.fill")
            case .ps1, .ps2, .ps3, .psp:
                Image(systemName: "circle.grid.cross.fill")
            case .xbox, .x360:
                Image(systemName: "x.circle.fill")
            case .dreamcast:
                Image(systemName: "circle.dashed")
            case .mame:
                Image(systemName: "gamecontroller.fill")
            }
        }
        .opacity(0.35)
        .font(.system(size: 14, weight: .bold))
    }
}

struct PlatformLabel: View {
    let platform: Platform
    var size: PlatformLabelSize = .regular

    var body: some View {
        HStack(spacing: size == .compact ? 6 : 8) {
            PlatformIcon(platform: platform, size: size)
                .fixedSize()

            Text(platform.displayName)
                .font(size.nameFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(platform.displayName)
    }
}
