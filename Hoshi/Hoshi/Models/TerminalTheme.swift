import SwiftTerm
import UIKit

// Curated dark terminal theme based on the Nord color palette
// https://www.nordtheme.com
//
// Nord's 16 ANSI colors map to polar night, snow storm, frost, and aurora groups.
// Background uses Nord0 (#2E3440), foreground uses Nord4 (#D8DEE9).
// WCAG AA contrast ratio for Nord4-on-Nord0 is ~9.3:1 (exceeds 4.5:1 requirement).
enum TerminalTheme {

    // Convert 8-bit (0-255) to 16-bit (0-65535) for SwiftTerm's Color(red:green:blue:)
    private static func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    // MARK: - Nord ANSI color palette (16 colors)

    static let ansiColors: [SwiftTerm.Color] = [
        // Normal colors (0-7)
        c(0x3B, 0x42, 0x52),  // 0: Black (Nord1)
        c(0xBF, 0x61, 0x6A),  // 1: Red (Nord11)
        c(0xA3, 0xBE, 0x8C),  // 2: Green (Nord14)
        c(0xEB, 0xCB, 0x8B),  // 3: Yellow (Nord13)
        c(0x81, 0xA1, 0xC1),  // 4: Blue (Nord9)
        c(0xB4, 0x8E, 0xAD),  // 5: Magenta (Nord15)
        c(0x88, 0xC0, 0xD0),  // 6: Cyan (Nord7)
        c(0xE5, 0xE9, 0xF0),  // 7: White (Nord5)

        // Bright colors (8-15)
        c(0x4C, 0x56, 0x6A),  // 8: Bright Black (Nord3)
        c(0xBF, 0x61, 0x6A),  // 9: Bright Red (Nord11)
        c(0xA3, 0xBE, 0x8C),  // 10: Bright Green (Nord14)
        c(0xEB, 0xCB, 0x8B),  // 11: Bright Yellow (Nord13)
        c(0x81, 0xA1, 0xC1),  // 12: Bright Blue (Nord9)
        c(0xB4, 0x8E, 0xAD),  // 13: Bright Magenta (Nord15)
        c(0x8F, 0xBC, 0xBB),  // 14: Bright Cyan (Nord8)
        c(0xEC, 0xEF, 0xF4),  // 15: Bright White (Nord6)
    ]

    // MARK: - Terminal background and foreground

    // Nord0 — Polar Night darkest
    static let backgroundColor = UIColor(red: 0x2E / 255.0, green: 0x34 / 255.0, blue: 0x40 / 255.0, alpha: 1.0)

    // Nord4 — Snow Storm lightest readable
    static let foregroundColor = UIColor(red: 0xD8 / 255.0, green: 0xDE / 255.0, blue: 0xE9 / 255.0, alpha: 1.0)

    // MARK: - Cursor

    // Nord8 — Frost bright cyan, high visibility on dark background
    static let cursorColor = UIColor(red: 0x88 / 255.0, green: 0xC0 / 255.0, blue: 0xD0 / 255.0, alpha: 1.0)

    // Nord0 — text under a block cursor
    static let cursorTextColor = UIColor(red: 0x2E / 255.0, green: 0x34 / 255.0, blue: 0x40 / 255.0, alpha: 1.0)

    // MARK: - UI chrome colors for status bar and banners

    // Nord1 — slightly lighter than background, for elevated surfaces
    static let chromeSurface = UIColor(red: 0x3B / 255.0, green: 0x42 / 255.0, blue: 0x52 / 255.0, alpha: 1.0)
}
