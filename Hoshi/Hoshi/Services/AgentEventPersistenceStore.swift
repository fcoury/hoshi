import Foundation

/// Stores a bounded, local event archive without credentials, approval commands, or terminal output.
final class AgentEventPersistenceStore {
    static let maximumEvents = 200

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "app.gethoshi.agent-events") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [AgentInboxEvent] {
        guard let data = defaults.data(forKey: key), data.count <= 1_048_576 else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let events = try? decoder.decode([AgentInboxEvent].self, from: data) else { return [] }
        return Array(events.prefix(Self.maximumEvents))
    }

    func save(_ events: [AgentInboxEvent]) {
        guard !events.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(events.prefix(Self.maximumEvents))) else { return }
        defaults.set(data, forKey: key)
    }
}
