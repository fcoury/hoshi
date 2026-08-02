import Foundation

/// Builds stable, mutually exclusive sidebar sections from persisted server profiles.
struct ServerCatalog {
    let favorites: [Server]
    let recent: [Server]
    let remaining: [Server]

    init(servers: [Server], searchText: String = "", recentLimit: Int = 5) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = servers.filter { server in
            query.isEmpty
                || server.name.localizedStandardContains(query)
                || server.hostname.localizedStandardContains(query)
                || server.username.localizedStandardContains(query)
                || (server.tmuxSession?.localizedStandardContains(query) ?? false)
        }

        favorites = matching
            .filter(\.isFavorite)
            .sorted(by: Self.mostRecentFirst)

        recent = Array(matching
            .filter { !$0.isFavorite && $0.lastConnected != nil }
            .sorted(by: Self.mostRecentFirst)
            .prefix(max(0, recentLimit)))

        let recentIDs = Set(recent.map(\.id))
        remaining = matching
            .filter { !$0.isFavorite && !recentIDs.contains($0.id) }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var isEmpty: Bool {
        favorites.isEmpty && recent.isEmpty && remaining.isEmpty
    }

    /// A single scan-friendly list while preserving favorites-first and recent ordering.
    var ordered: [Server] {
        favorites + recent + remaining
    }

    static func duplicatedName(from original: String, existingNames: some Sequence<String>) -> String {
        let existing = Set(existingNames)
        let baseName = "\(original) Copy"
        guard existing.contains(baseName) else { return baseName }

        var copyIndex = 2
        while existing.contains("\(baseName) \(copyIndex)") {
            copyIndex += 1
        }
        return "\(baseName) \(copyIndex)"
    }

    private static func mostRecentFirst(_ lhs: Server, _ rhs: Server) -> Bool {
        switch (lhs.lastConnected, rhs.lastConnected) {
        case let (left?, right?) where left != right:
            left > right
        case (_?, nil):
            true
        case (nil, _?):
            false
        default:
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
