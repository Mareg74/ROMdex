import AppKit
import SwiftUI

@main
struct ROMdexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var catalogViewModel = CatalogViewModel()
    @StateObject private var favoritesStore = FavoritesStore()
    @ObservedObject private var romsFunUnlock = RomsFunUnlockController.shared
    @ObservedObject private var coverLightbox = CoverArtLightboxController.shared
    @ObservedObject private var coverDiskCache = CoverImageDiskCache.shared
    @AppStorage(AppPreferences.clearCacheOnQuitKey) private var clearCacheOnQuit = false
    @AppStorage(AppPreferences.catalogCheckOnLaunchKey) private var catalogCheckOnLaunch = true
    @AppStorage(AppPreferences.catalogScrapeParallelKey) private var catalogScrapeParallel = false
    @AppStorage(AppPreferences.fetchParallelEnabledKey) private var fetchParallelEnabled = true

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(searchViewModel)
                .environmentObject(catalogViewModel)
                .environmentObject(favoritesStore)
                .environmentObject(romsFunUnlock)
                .environmentObject(coverLightbox)
                .environmentObject(coverDiskCache)
                .frame(minWidth: 800, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    coverDiskCache.refreshSize()
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("À propos de ROMdex") {
                    AboutROMdexPanel.shared.show()
                }
            }

            CommandMenu("Paramètres") {
                Button("Supprimer le cache") {
                    searchViewModel.clearAllCaches()
                    catalogViewModel.clearMemoryCache()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Vider le cache des vignettes (\(coverDiskCache.formattedByteSize))") {
                    let freed = coverDiskCache.formattedByteSize
                    coverDiskCache.clear()
                    catalogViewModel.showToast(list: "Cache vignettes", "Vidé (\(freed)).")
                }

                Toggle("Vider le cache à la fermeture", isOn: $clearCacheOnQuit)

                Toggle(
                    "Qualité maximum pour les vignettes",
                    isOn: $coverDiskCache.preferMaximumQuality
                )
                .help("Recharge les jaquettes depuis le réseau en pleine qualité pour l’affichage (session uniquement ; le disque reste en JPEG allégé).")

                Toggle("Vérifier les catalogues au démarrage", isOn: $catalogCheckOnLaunch)

                Toggle(
                    "Scrapes catalogues en parallèle",
                    isOn: Binding(
                        get: { catalogScrapeParallel },
                        set: { newValue in
                            catalogScrapeParallel = newValue
                            AppPreferences.catalogScrapeParallel = newValue
                        }
                    )
                )

                Toggle(
                    "Requêtes HTTP parallèles (recherche + listes)",
                    isOn: Binding(
                        get: { fetchParallelEnabled },
                        set: { newValue in
                            fetchParallelEnabled = newValue
                            AppPreferences.fetchParallelEnabled = newValue
                        }
                    )
                )
                .help("Plusieurs pages ou segments d’un même site sont récupérés en parallèle (max \(AppPreferences.fetchConcurrencyPerHost) par hôte).")

                Divider()

                Button("TheGamesDB API…") {
                    TheGamesDBClient.presentSettingsPanel()
                }

                Button("LaunchBox Metadata…") {
                    LaunchBoxMetadataClient.presentSettingsPanel()
                }

                Button("Débloquer RomsFun…") {
                    romsFunUnlock.present()
                }

                Button("Vérifier les mises à jour…") {
                    catalogViewModel.checkCatalogUpdates(force: true)
                }

                Button("Actualiser le catalogue") {
                    catalogViewModel.reload()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Actualiser tous les catalogues") {
                    catalogViewModel.refreshAllCatalogs()
                }

                Button("Reconstruire le catalogue (depuis zéro)") {
                    catalogViewModel.rebuild()
                }

                Button("Reconstruire les vignettes manquantes") {
                    catalogViewModel.promptAndRebuildMissingThumbnails()
                }

                Button("Reconstruire les dates manquantes ou erronées") {
                    catalogViewModel.promptAndRebuildReleaseYears()
                }

                Button("Vider le catalogue disque") {
                    catalogViewModel.clearDiskCatalog()
                }

                Divider()

                Button("Exporter le catalogue…") {
                    catalogViewModel.exportCatalog()
                }

                Button("Importer le catalogue (fusionner)…") {
                    catalogViewModel.importCatalog(merge: true)
                }

                Button("Importer le catalogue (remplacer)…") {
                    catalogViewModel.importCatalog(merge: false)
                }

                Divider()

                Button("Supprimer l’historique") {
                    searchViewModel.clearHistory()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}
