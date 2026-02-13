import Foundation

// Terminal cursor appearance style.
enum CursorStyle: String, CaseIterable, Identifiable, Codable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .block: "Block"
        case .bar: "Beam"
        case .underline: "Underline"
        }
    }

    // Ghostty config value for cursor-style
    var configValue: String {
        switch self {
        case .block: "block"
        case .bar: "bar"
        case .underline: "underline"
        }
    }
}
