# ROMdex

Indexeur de ROMs pour macOS — recherche multi-sites, filtre par plateforme, aperçu WebView et ouverture dans le navigateur.

## Fonctionnalités

- Recherche par titre sur **plusieurs sources en parallèle**
- Onglet **Tous les jeux** : catalogue par console (fusion multi-sites), tri A–Z / année / région / source
- Filtre par plateforme (**Switch** inclus)
- Liste agrégée avec dédoublonnage **multi-sources** (choix du site dans le détail)
- Aperçu de la page source dans l’app (WebKit)
- Bouton **Ouvrir dans le navigateur** pour télécharger
- Historique des recherches récentes
- **Cache** des 10 dernières recherches + 10 pages web préchargées (aperçu)
- **Catalogue disque** JSON par console (rechargement rapide ; hors cache WebKit)
- **Export / import** ZIP (`manifest.json` + `GBC.json`…) — fusionner ou remplacer
- Genre / type de jeu (NXBrew, Archive, pages détail) persisté dans le JSON

## Sources intégrées

| Source | Adapter | Notes |
|---|---|---|
| Vimm's Lair | `VimmAdapter` | |
| Retrostic | `RetrosticAdapter` | |
| CDRomance | `CDRomanceAdapter` | |
| Mondemul | `MondemulAdapter` | |
| Romspedia | `RomspediaAdapter` | Bon support Switch |
| RomHustler | `RomHustlerAdapter` | |
| RomUlation | `RomUlationAdapter` | |
| CoolROM | `CoolROMAdapter` | Souvent hors ligne (500) |
| DopeROMS | `DopeROMSAdapter` | Lander pub fréquent |
| RomsMania | `RomsManiaAdapter` | Anti-bot fréquent |
| Gamulator | `GamulatorAdapter` | Souvent indisponible |
| The ROM Depot | `ROMDepotAdapter` | API authentifiée |
| LostROMs | `LostROMsAdapter` | Via Old Games Download |
| ROMNation | `ROMNationAdapter` | Souvent hors ligne |
| The Old Computer | `TheOldComputerAdapter` | Parcours par dossiers |
| Xbox360ISO | `Xbox360ISOAdapter` | Xbox 360 (WP + table) |
| Internet Archive | `InternetArchiveAdapter` | Xbox / Xbox 360 |
| NXBrew | `NXBrewAdapter` | Nintendo Switch (NSP/XCI) |
| RomsFun | `RomsFunAdapter` | Gros catalogues ; Cloudflare → **Paramètres → Débloquer RomsFun…** |

### Surveillance des catalogues

- Empreintes légères (page 1) : RomHustler, Romspedia, RomsFun
- Pastille orange sur une console si changement détecté
- **Paramètres → Vérifier les mises à jour…** (manuel) ; option au démarrage (intervalle 24 h)
- Après actualisation : toast `+N nouveau(x) jeu(x)`
- **Actualiser** fusionne avec le JSON existant (jaquettes / année / genre conservés) ; **Reconstruire** efface et re-scrape depuis zéro
- File d’attente multi-consoles (spinners empilés) ; option **Scrapes catalogues en parallèle** (max 3 ; RomsFun/WebKit reste sérialisé)

> Certaines sources peuvent bloquer les requêtes automatisées (anti-bot) ou être hors ligne. L’app affiche alors un avertissement par source sans interrompre les autres.

## Prérequis

- macOS 13+
- Xcode 15+ ou Swift 5.9+ (uniquement pour compiler depuis les sources)

## Installation (release)

1. Téléchargez **`ROMdex.dmg`** depuis les [Releases GitHub](https://github.com/Mareg74/ROMdex/releases).
2. Ouvrez l’image disque : **ROMdex.app** s’affiche directement.
3. Glissez **ROMdex.app** vers le dossier **Applications**.
4. Au premier lancement (app non signée) : clic droit sur ROMdex → **Ouvrir**, puis confirmer.
5. Optionnel : téléchargez le **catalogue initial** (ZIP) sur la même release, puis **Import catalogue** dans l’app.

## Lancement (depuis les sources)

### Via Xcode

1. Ouvrir `Package.swift` dans Xcode
2. Sélectionner le schéma **ROMdex**
3. Run (⌘R)

### Via terminal

```bash
swift build
swift run ROMdex
```

## Structure

```
Sources/ROMdex/
├── Adapters/       # Parsers par site (SiteAdapter)
├── Models/         # Platform, GameResult
├── Services/       # HTTP, SearchEngine, historique
├── ViewModels/     # SearchViewModel
└── Views/          # SwiftUI + WKWebView
```

## Ajouter une source

1. Créer un fichier dans `Adapters/` conforme à `SiteAdapter`
2. Implémenter `search(query:platform:)`
3. Enregistrer l’adapter dans `SearchEngine`

## Plateformes

Game Boy, GBC, GBA, DS, 3DS, NES, SNES, N64, GameCube, Wii, Wii U, **Switch**, PS1, PS2, PSP, Xbox, Xbox 360, Dreamcast, MAME.

## Licence

Usage personnel et forks non commerciaux autorisés. Toute utilisation commerciale
requiert une autorisation écrite préalable. Voir [LICENSE](LICENSE).

## Avertissement

ROMdex est un outil de **recherche et navigation**. Il ne stocke ni ne distribue de ROMs. L’utilisateur est responsable du respect des lois et conditions d’utilisation des sites consultés.

## Catalogue initial (release)

Un ZIP de catalogues pré-scrapés est fourni en pièce jointe des **GitHub Releases**.
Import via le menu **Import catalogue** de l’application.
