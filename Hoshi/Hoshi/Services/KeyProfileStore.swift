import Foundation

/// Persists key sets, per-server pins, and the auto-switch preference.
///
/// The Shell set seeds from the classic `ToolbarConfigurationService` layout the
/// first time, so existing toolbar customizations carry over unchanged.
@MainActor @Observable
final class KeyProfileStore {
    static let shared = KeyProfileStore()

    private enum Key {
        static let profiles = "com.hoshi.keyProfiles.v1"
        static let pins = "com.hoshi.keyProfiles.pins"
        static let autoSwitch = "com.hoshi.keyProfiles.autoSwitch"
    }

    private let defaults: UserDefaults

    private(set) var profiles: [KeyProfile]

    /// Server ID → pinned key set ID.
    private(set) var pins: [String: String]

    var autoSwitch: Bool {
        didSet { defaults.set(autoSwitch, forKey: Key.autoSwitch) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoSwitch = defaults.object(forKey: Key.autoSwitch) as? Bool ?? true
        self.pins = defaults.dictionary(forKey: Key.pins) as? [String: String] ?? [:]

        let saved = defaults.data(forKey: Key.profiles)
            .flatMap { try? JSONDecoder().decode([KeyProfile].self, from: $0) } ?? []
        self.profiles = Self.merge(saved: saved)
    }

    /// Built-ins in canonical order, preferring saved versions; Shell seeds from legacy storage.
    private static func merge(saved: [KeyProfile]) -> [KeyProfile] {
        KeyProfile.builtInOrder.compactMap { id in
            if let stored = saved.first(where: { $0.id == id }) { return stored }
            if id == KeyProfile.shellID {
                var shell = KeyProfile.shell
                shell.keys = ToolbarConfigurationService.shared.loadButtons()
                return shell
            }
            return KeyProfile.builtIn(id)
        }
    }

    func profile(id: String) -> KeyProfile? {
        profiles.first { $0.id == id }
    }

    var shell: KeyProfile {
        profile(id: KeyProfile.shellID) ?? .shell
    }

    func update(_ profile: KeyProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        if profile.isShell {
            // Keep the legacy store in step for built-in keys.
            ToolbarConfigurationService.shared.saveButtons(profile.keys.filter { !$0.isCustom })
        }
        persist()
    }

    func reset(id: String) {
        guard let builtIn = KeyProfile.builtIn(id) else { return }
        if id == KeyProfile.shellID {
            ToolbarConfigurationService.shared.resetToDefaults()
        }
        update(builtIn)
    }

    // MARK: - Pins

    func pinnedProfileID(for serverID: UUID?) -> String? {
        guard let serverID else { return nil }
        return pins[serverID.uuidString]
    }

    func pin(_ profileID: String?, for serverID: UUID?) {
        guard let serverID else { return }
        pins[serverID.uuidString] = profileID
        defaults.set(pins, forKey: Key.pins)
    }

    func resolve(title: String?, serverID: UUID?, attachedID: String? = nil) -> KeyProfile {
        KeyProfileResolver.resolve(
            title: title,
            pinnedID: pinnedProfileID(for: serverID),
            attachedID: attachedID,
            autoSwitch: autoSwitch,
            profiles: profiles
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Key.profiles)
    }
}
