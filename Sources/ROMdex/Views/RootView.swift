import SwiftUI

struct RootView: View {
    @EnvironmentObject private var search: SearchViewModel
    @EnvironmentObject private var catalog: CatalogViewModel
    @EnvironmentObject private var romsFunUnlock: RomsFunUnlockController

    var body: some View {
        TabView {
            ContentView()
                .tabItem {
                    Label("Recherche", systemImage: "magnifyingglass")
                }

            CatalogView()
                .tabItem {
                    Label("Tous les jeux", systemImage: "square.grid.2x2")
                }

            FavoritesView()
                .tabItem {
                    Label("Favoris", systemImage: "star.fill")
                }
        }
        .overlay {
            CoverArtLightboxOverlay()
        }
        .sheet(isPresented: $romsFunUnlock.isPresented) {
            SiteUnlockSheet(
                siteName: "RomsFun",
                url: romsFunUnlock.unlockURL,
                onUnlocked: {
                    // Pas de re-scrape : le catalogue disque reste ; on reprend seulement l’enrichissement.
                    catalog.onRomsFunUnlocked()
                    search.clearRomsFunSourceErrors()
                    romsFunUnlock.dismiss()
                },
                onCancel: {
                    romsFunUnlock.dismiss()
                }
            )
        }
        .onAppear {
            catalog.checkCatalogUpdates(force: false)
            catalog.restoreInterruptedScrapeToastsIfNeeded()
        }
    }
}
