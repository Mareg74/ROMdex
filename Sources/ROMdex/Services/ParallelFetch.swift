import Foundation

/// Limite les requêtes HTTP simultanées par hôte (recherche + catalogue).
actor HostFetchLimiter {
    static let shared = HostFetchLimiter()

    private var inFlight: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withPermit<T>(for url: URL, operation: () async throws -> T) async rethrows -> T {
        let host = url.host?.lowercased() ?? "unknown"
        await acquire(host: host)
        defer { release(host: host) }
        return try await operation()
    }

    private func acquire(host: String) async {
        let limit = max(1, ParallelFetch.concurrency)
        if (inFlight[host] ?? 0) < limit {
            inFlight[host] = (inFlight[host] ?? 0) + 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters[host, default: []].append(continuation)
        }
    }

    private func release(host: String) {
        let limit = max(1, ParallelFetch.concurrency)
        let current = inFlight[host] ?? 0
        if current > 1 {
            inFlight[host] = current - 1
        } else {
            inFlight[host] = nil
        }

        if var queue = waiters[host], !queue.isEmpty {
            if (inFlight[host] ?? 0) < limit {
                let next = queue.removeFirst()
                if queue.isEmpty {
                    waiters[host] = nil
                } else {
                    waiters[host] = queue
                }
                inFlight[host] = (inFlight[host] ?? 0) + 1
                next.resume()
            }
        }
    }
}

/// Parallélisme borné pour scrapes paginés, recherches multi-segments, etc.
enum ParallelFetch {
    /// Concurrence effective (1 si parallélisme désactivé).
    static var concurrency: Int {
        guard AppPreferences.fetchParallelEnabled else { return 1 }
        return AppPreferences.fetchConcurrencyPerHost
    }

    /// Exécute `operation` pour chaque élément avec une concurrence max.
    static func map<T: Sendable, R: Sendable>(
        _ items: [T],
        concurrency limit: Int? = nil,
        _ operation: @Sendable @escaping (T) async throws -> R
    ) async rethrows -> [R] {
        guard !items.isEmpty else { return [] }

        let maxConcurrent = max(1, limit ?? concurrency)
        if maxConcurrent == 1 {
            var results: [R] = []
            results.reserveCapacity(items.count)
            for item in items {
                results.append(try await operation(item))
            }
            return results
        }

        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var nextIndex = 0
            var inFlight = 0

            func schedule() {
                while inFlight < maxConcurrent, nextIndex < items.count {
                    let index = nextIndex
                    nextIndex += 1
                    inFlight += 1
                    let item = items[index]
                    group.addTask {
                        let value = try await operation(item)
                        return (index, value)
                    }
                }
            }

            schedule()

            while inFlight > 0 {
                let (index, value) = try await group.next()!
                results[index] = value
                inFlight -= 1
                schedule()
            }

            return results.compactMap { $0 }
        }
    }

    /// Variante tolérante aux erreurs (pages vides, 404, etc.).
    static func mapOptional<T: Sendable, R: Sendable>(
        _ items: [T],
        concurrency limit: Int? = nil,
        _ operation: @Sendable @escaping (T) async -> R?
    ) async -> [R] {
        guard !items.isEmpty else { return [] }

        let maxConcurrent = max(1, limit ?? concurrency)
        if maxConcurrent == 1 {
            var results: [R] = []
            for item in items {
                if let value = await operation(item) {
                    results.append(value)
                }
            }
            return results
        }

        return await withTaskGroup(of: (Int, R?).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var nextIndex = 0
            var inFlight = 0

            func schedule() {
                while inFlight < maxConcurrent, nextIndex < items.count {
                    let index = nextIndex
                    nextIndex += 1
                    inFlight += 1
                    let item = items[index]
                    group.addTask {
                        let value = await operation(item)
                        return (index, value)
                    }
                }
            }

            schedule()

            while inFlight > 0 {
                if let (index, value) = await group.next() {
                    results[index] = value
                    inFlight -= 1
                    schedule()
                }
            }

            return results.compactMap { $0 }
        }
    }
}

/// Helper commun pour les listings paginés (catalogue + recherche locale).
enum PaginatedBrowse {
    /// Scrape les pages `firstPage...maxPages` avec parallélisme borné.
    /// La page 1 est toujours récupérée en premier (validation / erreurs).
    static func collect(
        from firstPage: Int = 1,
        through maxPages: Int,
        siteName: String,
        fetchPage: @Sendable @escaping (Int) async throws -> [GameResult]
    ) async throws -> [GameResult] {
        guard maxPages >= firstPage else { return [] }

        var seen = Set<String>()
        var all: [GameResult] = []

        func absorb(_ batch: [GameResult]) {
            var pageBatch: [GameResult] = []
            for item in batch {
                if seen.insert(item.pageURL.absoluteString).inserted {
                    all.append(item)
                    pageBatch.append(item)
                }
            }
            if !pageBatch.isEmpty {
                CatalogBrowseProgress.reportGames(site: siteName, pageBatch)
            }
        }

        let first = try await fetchPage(firstPage)
        absorb(first)

        guard maxPages > firstPage else { return all }

        let remaining = Array((firstPage + 1) ... maxPages)
        let limit = ParallelFetch.concurrency

        if limit <= 1 {
            for page in remaining {
                guard let batch = try? await fetchPage(page) else { break }
                if batch.isEmpty { break }
                absorb(batch)
            }
            return all
        }

        let batches = await ParallelFetch.mapOptional(remaining, concurrency: limit) { page -> [GameResult]? in
            do {
                return try await fetchPage(page)
            } catch {
                return nil
            }
        }

        for batch in batches {
            if batch.isEmpty { continue }
            absorb(batch)
        }

        return all
    }

    /// Fusionne des lots déjà récupérés (ex. page 1 + pages parallèles).
    static func merge(
        siteName: String,
        batches: [[GameResult]]
    ) -> [GameResult] {
        var seen = Set<String>()
        var all: [GameResult] = []

        for batch in batches {
            var pageBatch: [GameResult] = []
            for item in batch {
                if seen.insert(item.pageURL.absoluteString).inserted {
                    all.append(item)
                    pageBatch.append(item)
                }
            }
            if !pageBatch.isEmpty {
                CatalogBrowseProgress.reportGames(site: siteName, pageBatch)
            }
        }

        return all
    }
}
