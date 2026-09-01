import SwiftUI

struct RegionBadge: View {
    let region: GameRegion
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(region.flagEmoji)
                .font(compact ? .caption2 : .subheadline)
            Text(region.displayName)
                .font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(region.badgeColor, in: Capsule())
        .accessibilityLabel(region.fullName)
    }
}
