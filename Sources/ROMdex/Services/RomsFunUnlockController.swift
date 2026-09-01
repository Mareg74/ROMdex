import Foundation

/// Contrôle la feuille « Débloquer RomsFun » (challenge Cloudflare visible une fois).
@MainActor
final class RomsFunUnlockController: ObservableObject {
    static let shared = RomsFunUnlockController()

    @Published var isPresented = false

    /// URL hub catalogue — suffit pour poser les cookies Cloudflare du domaine.
    let unlockURL = URL(string: "https://romsfun.com/roms/")!

    private init() {}

    func present() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}
