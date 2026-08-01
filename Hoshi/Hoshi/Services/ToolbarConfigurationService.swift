import Foundation

// Persists the user's toolbar button configuration across app launches
// Uses UserDefaults to store an ordered list of button IDs
final class ToolbarConfigurationService {
    static let shared = ToolbarConfigurationService()

    private let key = "com.hoshi.toolbar.buttons"
    private let defaults = UserDefaults.standard

    // Lookup table: button ID → ToolbarButton
    private let buttonsByID: [String: ToolbarButton] = {
        var map: [String: ToolbarButton] = [:]
        for button in ToolbarButton.allAvailable {
            map[button.id] = button
        }
        return map
    }()

    private init() {}

    // Load the saved toolbar layout, falling back to defaults
    func loadButtons() -> [ToolbarButton] {
        guard let savedIDs = defaults.stringArray(forKey: key) else {
            return ToolbarButton.defaultButtons
        }

        // Upgrade previous untouched defaults as semantic Paste and Voice actions are introduced,
        // while preserving deliberately customized layouts verbatim.
        let currentDefaults = ToolbarButton.defaultButtons
        let priorDefaultLayouts = [
            currentDefaults.filter { $0.id != ToolbarButton.voicePrompt.id },
            currentDefaults.filter { $0.id != ToolbarButton.paste.id },
            currentDefaults.filter {
                $0.id != ToolbarButton.paste.id && $0.id != ToolbarButton.voicePrompt.id
            },
        ]
        if priorDefaultLayouts.contains(where: { $0.map(\.id) == savedIDs }) {
            saveButtons(ToolbarButton.defaultButtons)
            return ToolbarButton.defaultButtons
        }

        // Resolve IDs to buttons, skipping any that no longer exist
        let buttons = savedIDs.compactMap { buttonsByID[$0] }
        return buttons.isEmpty ? ToolbarButton.defaultButtons : buttons
    }

    // Save the current toolbar layout as an ordered list of IDs
    func saveButtons(_ buttons: [ToolbarButton]) {
        let ids = buttons.map(\.id)
        defaults.set(ids, forKey: key)
    }

    // Reset to default layout
    func resetToDefaults() {
        defaults.removeObject(forKey: key)
    }
}
