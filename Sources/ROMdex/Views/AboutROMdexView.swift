import AppKit
import SwiftUI

enum AboutROMdexMetadata {
    static let author = "Mareg74"
    static let githubURL = URL(string: "https://github.com/Mareg74")!
    static let githubLabel = "github.com/Mareg74"
    static let version = "1.0.0"
}

struct AboutROMdexView: View {
    var body: some View {
        VStack(spacing: 12) {
            if let icon = AboutROMdexAssets.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 128, height: 128)
            }

            Text("ROMdex")
                .font(.system(size: 26, weight: .bold))

            Text("Version \(AboutROMdexMetadata.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Indexeur de ROMs pour macOS")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 24)

            Text(AboutROMdexMetadata.author)
                .font(.headline)

            Link(AboutROMdexMetadata.githubLabel, destination: AboutROMdexMetadata.githubURL)
                .font(.subheadline)

            Text("© 2026 \(AboutROMdexMetadata.author)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 340)
    }
}

enum AboutROMdexAssets {
    static var appIcon: NSImage? {
        if let url = Bundle.module.url(forResource: "AppIcon-About", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }
}

@MainActor
final class AboutROMdexPanel {
    static let shared = AboutROMdexPanel()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutROMdexView())
            let panel = NSWindow(contentViewController: hosting)
            panel.title = "À propos de ROMdex"
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.setContentSize(NSSize(width: 340, height: 400))
            panel.center()
            window = panel
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
