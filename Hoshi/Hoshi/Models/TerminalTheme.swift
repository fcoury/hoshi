import UIKit

// Curated dark terminal theme based on the Nord color palette.
enum TerminalTheme {
    private static func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UIColor {
        UIColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    // MARK: - Nord ANSI color palette (16 colors)

    static let ansiColors: [UIColor] = [
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

    static let backgroundColor = c(0x2E, 0x34, 0x40)
    static let foregroundColor = c(0xD8, 0xDE, 0xE9)

    // MARK: - Cursor

    static let cursorColor = c(0x88, 0xC0, 0xD0)
    static let cursorTextColor = c(0x2E, 0x34, 0x40)

    // MARK: - UI chrome colors

    static let chromeSurface = c(0x3B, 0x42, 0x52)
}
