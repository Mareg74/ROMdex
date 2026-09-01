import Foundation

/// The Old Computer — arborescence dirLIST (`/roms/index.php?folder=`).
/// Scrapable en invité pour Sony / Microsoft / Sega / MAME ; Nintendo fermé (DMCA).
struct TheOldComputerAdapter: SiteAdapter {
    let id = "theoldcomputer"
    let displayName = "The Old Computer"
    private let baseURL = URL(string: "https://www.theoldcomputer.com")!
    private let maxBrowseDepth = 7
    private let maxFolderVisits = 900
    private let maxGames = 25_000

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let folders: [(Platform, String)]
        if let platform {
            guard let folder = platform.oldComputerFolder else {
                throw SiteAdapterError.unsupportedPlatform(platform)
            }
            folders = [(platform, folder)]
        } else {
            folders = Platform.allCases.compactMap { p in
                guard let folder = p.oldComputerFolder else { return nil }
                return (p, folder)
            }
        }

        return await ParallelFetch.map(folders) { platform, folder in
            await self.searchFolder(query: trimmed, platform: platform, folder: folder)
        }.flatMap { $0 }
    }

    func browse(platform: Platform) async throws -> [GameResult] {
        guard let roots = platform.oldComputerBrowseRoots, !roots.isEmpty else {
            throw SiteAdapterError.unsupportedPlatform(platform)
        }

        let state = CrawlState(maxFolderVisits: maxFolderVisits, maxGames: maxGames)
        var all: [GameResult] = []

        for root in roots {
            let batch = await crawl(folder: root, platform: platform, depth: 0, state: state)
            all.append(contentsOf: batch)
            if state.gameCount() >= maxGames { break }
        }

        CatalogBrowseProgress.reportGames(site: displayName, all)
        return all
    }

    // MARK: - Crawl

    private func crawl(folder: String, platform: Platform, depth: Int, state: CrawlState) async -> [GameResult] {
        guard depth <= maxBrowseDepth else { return [] }
        guard state.beginFolder(folder) else { return [] }

        guard let html = try? await fetchFolderHTML(folder) else { return [] }
        if isClosedOrBlocked(html) { return [] }

        var results = parseFiles(html: html, platform: platform, folder: folder, state: state)

        let subfolders = parseSubfolders(html: html, parentFolder: folder)
        if depth < maxBrowseDepth, !subfolders.isEmpty, state.gameCount() < maxGames {
            let batches = await ParallelFetch.mapOptional(subfolders) { sub -> [GameResult]? in
                let batch = await self.crawl(folder: sub, platform: platform, depth: depth + 1, state: state)
                return batch.isEmpty ? nil : batch
            }
            for batch in batches {
                results.append(contentsOf: batch)
                if state.gameCount() >= maxGames { break }
            }
        }

        return results
    }

    private func searchFolder(query: String, platform: Platform, folder: String) async -> [GameResult] {
        guard let html = try? await fetchFolderHTML(folder) else { return [] }
        if isClosedOrBlocked(html) { return [] }
        return parseSearchResults(html: html, platform: platform, query: query, folder: folder)
    }

    private func fetchFolderHTML(_ folder: String) async throws -> String {
        let encoded = folder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folder
        guard let url = URL(string: "https://www.theoldcomputer.com/roms/index.php?folder=\(encoded)") else {
            throw SiteAdapterError.invalidResponse
        }
        return try await HTTPClient.fetchString(from: url, timeout: 45)
    }

    private func isClosedOrBlocked(_ html: String) -> Bool {
        html.localizedCaseInsensitiveContains("perm_closed")
            || html.localizedCaseInsensitiveContains("do not make available, distribute, sell")
    }

    // MARK: - Parse

    private func parseSubfolders(html: String, parentFolder: String) -> [String] {
        let pattern = #"<tr[^>]*class="folder_bg"[^>]*>[\s\S]*?<a href="index\.php\?folder=([^"]+)"[^>]*>"#
        var seen = Set<String>()
        var folders: [String] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = HTMLParser.decodeEntities(match.groups[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            guard path.hasPrefix(parentFolder + "/") else { continue }
            guard !path.localizedCaseInsensitiveContains("adult-games") else { continue }
            guard seen.insert(path).inserted else { continue }
            folders.append(path)
        }

        return folders
    }

    private func parseFiles(html: String, platform: Platform, folder: String, state: CrawlState) -> [GameResult] {
        let pattern = #"<a href="(getfile\.php\?file=[^"]+)"[^>]*>\s*([^<]+)\s*</a>"#
        var results: [GameResult] = []
        var pageBatch: [GameResult] = []

        for match in HTMLParser.matches(in: html, pattern: pattern) {
            let path = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 1 else { continue }
            guard let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard state.tryInsertGame(url: pageURL.absoluteString) else { continue }

            let game = GameResult(
                title: title,
                platform: platform,
                sourceSite: displayName,
                pageURL: pageURL,
                regionHint: folder
            )
            results.append(game)
            pageBatch.append(game)
            if state.gameCount() >= maxGames { break }
        }

        if !pageBatch.isEmpty {
            CatalogBrowseProgress.reportGames(site: displayName, pageBatch)
        }

        return results
    }

    private func parseSearchResults(html: String, platform: Platform, query: String, folder: String) -> [GameResult] {
        let needle = query.lowercased()
        var seen = Set<String>()
        var results: [GameResult] = []

        let folderPattern = #"<a href="(/roms/index\.php\?folder=[^"]+)"[^>]*>\s*([^<]+)</a>"#
        for match in HTMLParser.matches(in: html, pattern: folderPattern) {
            let path = HTMLParser.decodeEntities(match.groups[0])
            let title = HTMLParser.decodeEntities(match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.lowercased().contains(needle) else { continue }
            guard !title.hasSuffix("/") else { continue }
            guard let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: folder
                )
            )
        }

        let filePattern = #"<a href="(getfile\.php\?file=[^"]+)"[^>]*>\s*([^<]+)\s*</a>"#
        for match in HTMLParser.matches(in: html, pattern: filePattern) {
            let path = match.groups[0]
            let title = HTMLParser.decodeEntities(match.groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.lowercased().contains(needle) else { continue }
            guard let pageURL = HTTPClient.absoluteURL(path, base: baseURL) else { continue }
            guard seen.insert(pageURL.absoluteString).inserted else { continue }

            results.append(
                GameResult(
                    title: title,
                    platform: platform,
                    sourceSite: displayName,
                    pageURL: pageURL,
                    regionHint: folder
                )
            )
        }

        return results
    }
}

// MARK: - Crawl state

private final class CrawlState: @unchecked Sendable {
    private let lock = NSLock()
    private var visitedFolders = Set<String>()
    private var seenGameURLs = Set<String>()
    private var gamesFound = 0
    private let maxFolderVisits: Int
    private let maxGames: Int

    init(maxFolderVisits: Int, maxGames: Int) {
        self.maxFolderVisits = maxFolderVisits
        self.maxGames = maxGames
    }

    func beginFolder(_ folder: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard visitedFolders.count < maxFolderVisits else { return false }
        guard gamesFound < maxGames else { return false }
        return visitedFolders.insert(folder).inserted
    }

    func gameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return gamesFound
    }

    func tryInsertGame(url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard gamesFound < maxGames else { return false }
        guard seenGameURLs.insert(url).inserted else { return false }
        gamesFound += 1
        return true
    }
}
