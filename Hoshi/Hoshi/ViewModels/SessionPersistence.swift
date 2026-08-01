import Foundation

/// Resume metadata only; credentials, rendered terminal contents, and thumbnails stay out of UserDefaults.
struct PersistedSessionDescriptor: Codable, Equatable, Sendable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let transportPolicy: ConnectionTransportPolicy
    let tmuxSession: String?
    let createdAt: Date
    let lastAccessedAt: Date
}

final class SessionPersistenceStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "app.gethoshi.active-session-descriptors") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [PersistedSessionDescriptor] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PersistedSessionDescriptor].self, from: data)) ?? []
    }

    func save(_ descriptors: [PersistedSessionDescriptor]) {
        guard !descriptors.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        defaults.set(data, forKey: key)
    }
}
