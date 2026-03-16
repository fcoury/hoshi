import Foundation
import UIKit

// Persists all appearance preferences across app launches.
// Reads/writes UserDefaults with key prefix "com.hoshi.appearance".
@MainActor @Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let themeID = "com.hoshi.appearance.themeID"
        static let fontFamily = "com.hoshi.appearance.fontFamily"
        static let fontSize = "com.hoshi.appearance.fontSize"
        static let cursorStyle = "com.hoshi.appearance.cursorStyle"
        static let backgroundOpacity = "com.hoshi.appearance.backgroundOpacity"
        static let colorScheme = "com.hoshi.appearance.colorScheme"
        static let scrollMultiplier = "com.hoshi.appearance.scrollMultiplier"
    }

    var themeID: String {
        didSet { defaults.set(themeID, forKey: Key.themeID) }
    }

    var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: Key.fontSize) }
    }

    var cursorStyle: CursorStyle {
        didSet { defaults.set(cursorStyle.rawValue, forKey: Key.cursorStyle) }
    }

    var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity) }
    }

    var colorScheme: ColorSchemePreference {
        didSet { defaults.set(colorScheme.rawValue, forKey: Key.colorScheme) }
    }

    var scrollMultiplier: Double {
        didSet { defaults.set(scrollMultiplier, forKey: Key.scrollMultiplier) }
    }

    // Resolved theme object from the current themeID
    var currentTheme: TerminalTheme {
        TerminalTheme.theme(for: themeID)
    }

    // Hash of all settings for cheap change detection in live updates
    var settingsHash: Int {
        var hasher = Hasher()
        hasher.combine(themeID)
        hasher.combine(fontFamily)
        hasher.combine(fontSize)
        hasher.combine(cursorStyle)
        hasher.combine(backgroundOpacity)
        hasher.combine(colorScheme)
        hasher.combine(scrollMultiplier)
        return hasher.finalize()
    }

    private init() {
        self.themeID = defaults.string(forKey: Key.themeID) ?? "nord"
        self.fontFamily = defaults.string(forKey: Key.fontFamily) ?? "FantasqueSansM Nerd Font Mono"

        let savedSize = defaults.double(forKey: Key.fontSize)
        self.fontSize = savedSize > 0 ? CGFloat(savedSize) : 14

        if let raw = defaults.string(forKey: Key.cursorStyle),
           let style = CursorStyle(rawValue: raw) {
            self.cursorStyle = style
        } else {
            self.cursorStyle = .block
        }

        let savedOpacity = defaults.object(forKey: Key.backgroundOpacity) as? Double
        self.backgroundOpacity = savedOpacity ?? 1.0

        if let raw = defaults.string(forKey: Key.colorScheme),
           let scheme = ColorSchemePreference(rawValue: raw) {
            self.colorScheme = scheme
        } else {
            self.colorScheme = .dark
        }

        let savedMultiplier = defaults.object(forKey: Key.scrollMultiplier) as? Double
        self.scrollMultiplier = savedMultiplier ?? 3.0
    }
}
