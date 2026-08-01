import SwiftUI

// User's preferred color scheme for the terminal.
enum ColorSchemePreference: String, CaseIterable, Identifiable, Codable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}
