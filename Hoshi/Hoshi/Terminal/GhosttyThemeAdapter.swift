import UIKit
import GhosttyKit

// Builds Ghostty configuration strings from AppearanceSettings.
@MainActor
enum GhosttyThemeAdapter {

    // Apply current AppearanceSettings to a Ghostty config (used at init time)
    static func apply(to config: ghostty_config_t) {
        let configString = buildConfigString(from: AppearanceSettings.shared)
        configString.withCString { ptr in
            ghostty_config_load_string(config, ptr, UInt(configString.utf8.count))
        }
    }

    // Build the full Ghostty config string from the given settings
    static func buildConfigString(from settings: AppearanceSettings) -> String {
        let theme = settings.currentTheme
        var lines: [String] = []

        // Colors
        lines.append("background = \(hex(theme.background, includeHash: false))")
        lines.append("foreground = \(hex(theme.foreground, includeHash: false))")
        lines.append("cursor-color = \(hex(theme.cursorColor, includeHash: false))")
        lines.append("cursor-text = \(hex(theme.cursorText, includeHash: false))")
        lines.append("selection-background = \(hex(theme.selectionBackground, includeHash: false))")
        lines.append("selection-foreground = \(hex(theme.selectionForeground, includeHash: false))")

        // ANSI palette
        for (index, color) in theme.palette.enumerated() {
            lines.append("palette = \(index)=\(hex(color, includeHash: true))")
        }

        // Font
        lines.append("font-family = \"\(settings.fontFamily)\"")
        lines.append("font-size = \(Double(settings.fontSize))")
        lines.append("window-inherit-font-size = false")

        // Cursor style
        lines.append("cursor-style = \(settings.cursorStyle.configValue)")

        // Background opacity
        lines.append("background-opacity = \(settings.backgroundOpacity)")

        return lines.joined(separator: "\n")
    }

    // Apply settings to an existing Ghostty config object
    static func apply(to config: ghostty_config_t, settings: AppearanceSettings) {
        let configString = buildConfigString(from: settings)
        configString.withCString { ptr in
            ghostty_config_load_string(config, ptr, UInt(configString.utf8.count))
        }
    }

    static func hex(_ color: UIColor, includeHash: Bool) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        let prefix = includeHash ? "#" : ""

        return String(format: "\(prefix)%02x%02x%02x", r, g, b)
    }
}
