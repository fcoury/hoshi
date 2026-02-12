import UIKit
import GhosttyKit

// Applies the app's terminal theme to Ghostty configuration.
enum GhosttyThemeAdapter {
    static func apply(to config: ghostty_config_t, fontSize: CGFloat) {
        var lines: [String] = []

        lines.append("background = \(hex(TerminalTheme.backgroundColor, includeHash: false))")
        lines.append("foreground = \(hex(TerminalTheme.foregroundColor, includeHash: false))")
        lines.append("cursor-color = \(hex(TerminalTheme.cursorColor, includeHash: false))")
        lines.append("cursor-text = \(hex(TerminalTheme.cursorTextColor, includeHash: false))")

        for (index, color) in TerminalTheme.ansiColors.enumerated() {
            lines.append("palette = \(index)=\(hex(color, includeHash: true))")
        }

        lines.append("font-family = \"FantasqueSansM Nerd Font Mono\"")
        lines.append("font-size = \(Double(fontSize))")
        lines.append("window-inherit-font-size = false")

        let configString = lines.joined(separator: "\n")
        configString.withCString { ptr in
            ghostty_config_load_string(config, ptr, UInt(configString.utf8.count))
        }
    }

    private static func hex(_ color: UIColor, includeHash: Bool) -> String {
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
