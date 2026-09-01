import Foundation

/// Surveille les listings (page 1) RomHustler / Romspedia / RomsFun et signale les consoles à jour.
@MainActor
final class CatalogUpdateMonitor: ObservableObject {
    static let shared = CatalogUpdateMonitor()

    @Published private(set) var flaggedPlatforms: Set<Platform> = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var statusMessage: String?

    private var state = CatalogFingerprintState()
    private var checkTask: Task<Void, Never>?

    private init() {
        reloadFromDisk()
    }

    func reloadFromDisk() {
        state = CatalogFingerprintStore.load()
        flaggedPlatforms = Set(state.flaggedPlatforms.compactMap(Platform.init(rawValue:)))
        lastCheckAt = state.lastCheckAt
    }

    /// Vérifie si l’intervalle est écoulé (ou `force`), puis lance le check.
    func checkIfNeeded(force: Bool = false) {
        if !force {
            guard AppPreferences.catalogCheckOnLaunch else { return }
            if let last = state.lastCheckAt {
                let hours = AppPreferences.catalogCheckIntervalHours
                let elapsed = Date().timeIntervalSince(last)
                guard elapsed >= Double(hours) * 3600 else { return }
            }
            // Auto : sources HTTP rapides seulement (pas RomsFun / WebKit).
            checkAll(includeRomsFun: false)
            return
        }
        checkAll(includeRomsFun: true)
    }

    func checkAll(includeRomsFun: Bool = true) {
        checkTask?.cancel()
        isChecking = true
        statusMessage = "Vérification des catalogues…"
        checkTask = Task { @MainActor in
            await runCheck(includeRomsFun: includeRomsFun)
        }
    }

    func clearFlag(for platform: Platform) {
        state.clearFlag(platform)
        flaggedPlatforms.remove(platform)
        CatalogFingerprintStore.save(state)
    }

    /// Après un scrape réussi : met à jour les empreintes (nouvelle baseline) et lève le drapeau.
    func refreshBaseline(for platform: Platform) async {
        _ = await probePlatform(
            platform,
            updateBaseline: true,
            flagOnChange: false,
            includeRomsFun: true
        )
        state.clearFlag(platform)
        flaggedPlatforms.remove(platform)
        CatalogFingerprintStore.save(state)
    }

    // MARK: - Check

    private func runCheck(includeRomsFun: Bool) async {
        statusMessage = "Vérification des catalogues…"
        defer { isChecking = false }

        var changed: [Platform] = []
        let cached = Platform.allCases.filter {
            CatalogDiskStore.load($0) != nil && Self.isMonitorable($0)
        }
        let platforms = cached.isEmpty
            ? Platform.allCases.filter { Self.isMonitorable($0) }
            : cached

        for (index, platform) in platforms.enumerated() {
            guard !Task.isCancelled else { break }
            statusMessage = "Vérification \(platform.displayName) (\(index + 1)/\(platforms.count))…"
            let didChange = await probePlatform(
                platform,
                updateBaseline: false,
                flagOnChange: true,
                includeRomsFun: includeRomsFun
            )
            if didChange {
                changed.append(platform)
            }
        }

        state.lastCheckAt = Date()
        lastCheckAt = state.lastCheckAt
        CatalogFingerprintStore.save(state)
        flaggedPlatforms = Set(state.flaggedPlatforms.compactMap(Platform.init(rawValue:)))

        if changed.isEmpty {
            statusMessage = "Catalogues à jour."
        } else {
            let names = changed.map(\.displayName).joined(separator: ", ")
            statusMessage = "Mises à jour possibles : \(names)."
        }
    }

    /// - Returns: `true` si au moins une source a changé par rapport à l’empreinte connue.
    @discardableResult
    private func probePlatform(
        _ platform: Platform,
        updateBaseline: Bool,
        flagOnChange: Bool,
        includeRomsFun: Bool
    ) async -> Bool {
        var anyChange = false

        if let slug = platform.romHustlerListingSlug,
           let url = URL(string: "https://romhustler.org/roms/\(slug)"),
           let html = try? await HTTPClient.fetchString(from: url, timeout: 18),
           let fp = CatalogFingerprint.fromRomHustlerHTML(html) {
            if applyFingerprint(
                fp,
                platform: platform,
                sourceID: "romhustler",
                updateBaseline: updateBaseline,
                flagOnChange: flagOnChange
            ) {
                anyChange = true
            }
        }

        if let slug = platform.romspediaSlug,
           let url = URL(string: "https://www.romspedia.com/roms/\(slug)"),
           let html = try? await HTTPClient.fetchString(from: url, timeout: 18),
           let fp = CatalogFingerprint.fromRomspediaHTML(html, slug: slug) {
            if applyFingerprint(
                fp,
                platform: platform,
                sourceID: "romspedia",
                updateBaseline: updateBaseline,
                flagOnChange: flagOnChange
            ) {
                anyChange = true
            }
        }

        if includeRomsFun,
           let slug = platform.romsFunSlug,
           let url = URL(string: "https://romsfun.com/roms/\(slug)/"),
           let html = try? await BrowserHTMLClient.shared.fetchHTML(from: url, timeout: 35),
           let fp = CatalogFingerprint.fromRomsFunHTML(html, slug: slug) {
            if applyFingerprint(
                fp,
                platform: platform,
                sourceID: "romsfun",
                updateBaseline: updateBaseline,
                flagOnChange: flagOnChange
            ) {
                anyChange = true
            }
        }

        return anyChange
    }

    private func applyFingerprint(
        _ fingerprint: String,
        platform: Platform,
        sourceID: String,
        updateBaseline: Bool,
        flagOnChange: Bool
    ) -> Bool {
        let key = CatalogFingerprintState.storageKey(platform: platform, sourceID: sourceID)
        let previous = state.fingerprints[key]

        if previous == nil || updateBaseline {
            state.fingerprints[key] = fingerprint
            return false
        }

        if previous != fingerprint {
            state.fingerprints[key] = fingerprint
            if flagOnChange {
                state.flag(platform)
            }
            return true
        }
        return false
    }

    static func isMonitorable(_ platform: Platform) -> Bool {
        platform.romHustlerListingSlug != nil
            || platform.romspediaSlug != nil
            || platform.romsFunSlug != nil
    }
}
