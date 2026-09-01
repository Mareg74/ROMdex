import Foundation

/// The ROM Depot est une SPA avec API authentifiée — pas de catalogue public scrapable.
struct ROMDepotAdapter: SiteAdapter {
    let id = "romdepot"
    let displayName = "The ROM Depot"
    private let apiURL = URL(string: "https://theromdepot.com/api/getContents")!

    func search(query: String, platform: Platform?) async throws -> [GameResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = URLRequest(url: apiURL)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return []
        }

        // Catalogue derrière login → rien à indexer sans compte.
        if http.statusCode == 401 || http.statusCode == 403 {
            return []
        }

        guard (200 ... 299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        return parseJSON(json, query: trimmed, platform: platform)
    }

    private func parseJSON(_ json: Any, query: String, platform: Platform?) -> [GameResult] {
        let needle = query.lowercased()
        var names: [(String, String)] = []

        func walk(_ node: Any, path: String) {
            if let dict = node as? [String: Any] {
                let name = (dict["name"] as? String)
                    ?? (dict["filename"] as? String)
                    ?? (dict["path"] as? String)
                if let name, name.lowercased().contains(needle) {
                    names.append((name, path.isEmpty ? name : path))
                }
                for (key, value) in dict {
                    walk(value, path: path.isEmpty ? key : "\(path)/\(key)")
                }
            } else if let array = node as? [Any] {
                for item in array {
                    walk(item, path: path)
                }
            }
        }

        walk(json, path: "")

        var seen = Set<String>()
        return names.compactMap { name, path in
            let title = name
                .replacingOccurrences(of: #"\.[a-z0-9]+$"#, with: "", options: .regularExpression)
            guard seen.insert(title.lowercased()).inserted else { return nil }
            guard let pageURL = URL(string: "https://theromdepot.com/") else { return nil }
            return GameResult(
                title: title,
                platform: platform ?? .snes,
                sourceSite: displayName,
                pageURL: pageURL,
                regionHint: path
            )
        }
    }
}
