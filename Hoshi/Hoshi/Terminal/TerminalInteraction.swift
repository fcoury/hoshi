import Foundation
import CoreGraphics
import UIKit

/// Keeps terminal clipboard access injectable so tests never touch the user's system pasteboard.
@MainActor
enum TerminalPasteboard {
    static var shared: UIPasteboard = .general
}

enum TerminalDoubleTapAction: String, CaseIterable, Identifiable {
    case selectWord
    case paste
    case showMenu
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selectWord: "Select Word"
        case .paste: "Paste"
        case .showMenu: "Show Edit Menu"
        case .disabled: "Disabled"
        }
    }
}

enum TerminalTwoFingerTapAction: String, CaseIterable, Identifiable {
    case paste
    case showMenu
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paste: "Paste"
        case .showMenu: "Show Edit Menu"
        case .disabled: "Disabled"
        }
    }
}

enum TerminalPasteRisk: Equatable {
    case multiline(lineCount: Int)
    case large(byteCount: Int)
    case bracketTerminator
}

struct TerminalPasteAssessment: Equatable {
    let byteCount: Int
    let lineCount: Int
    let bracketedPasteEnabled: Bool
    let risks: [TerminalPasteRisk]

    var requiresConfirmation: Bool {
        !risks.isEmpty
    }

    var confirmationMessage: String {
        if risks.contains(.bracketTerminator) {
            return "This text contains a terminal control sequence that can escape bracketed-paste protection."
        }

        if case .large(let count)? = risks.first(where: {
            if case .large = $0 { return true }
            return false
        }) {
            return "Paste \(lineCount) lines containing \(count.formatted()) bytes into the terminal?"
        }

        return "Paste \(lineCount) lines into the terminal? Newlines can execute multiple commands."
    }
}

enum TerminalPastePolicy {
    static let largePasteThreshold = 4_096
    private static let bracketTerminator = "\u{1B}[201~"

    static func assess(_ content: String, bracketedPasteEnabled: Bool) -> TerminalPasteAssessment {
        let byteCount = content.utf8.count
        let newlineCount = content.reduce(into: 0) { count, character in
            if character.isNewline {
                count += 1
            }
        }
        let lineCount = content.isEmpty ? 0 : newlineCount + 1

        var risks: [TerminalPasteRisk] = []
        if content.contains(bracketTerminator) {
            risks.append(.bracketTerminator)
        }
        if newlineCount > 0 && !bracketedPasteEnabled {
            risks.append(.multiline(lineCount: lineCount))
        }
        if byteCount >= largePasteThreshold {
            risks.append(.large(byteCount: byteCount))
        }

        return TerminalPasteAssessment(
            byteCount: byteCount,
            lineCount: lineCount,
            bracketedPasteEnabled: bracketedPasteEnabled,
            risks: risks
        )
    }
}

enum TerminalClipboardRequestKind: Equatable {
    case paste
    case remoteRead
    case remoteWrite

    var title: String {
        switch self {
        case .paste:
            return "Confirm Paste"
        case .remoteRead:
            return "Allow Clipboard Access?"
        case .remoteWrite:
            return "Allow Clipboard Change?"
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .paste:
            return "Paste"
        case .remoteRead, .remoteWrite:
            return "Allow"
        }
    }
}

struct TerminalClipboardRequest: Identifiable {
    let id = UUID()
    let content: String
    let kind: TerminalClipboardRequestKind
    let assessment: TerminalPasteAssessment
    let onDecision: @MainActor (Bool) -> Void

    var message: String {
        switch kind {
        case .paste:
            return assessment.confirmationMessage
        case .remoteRead:
            return "The remote application wants to read your device clipboard."
        case .remoteWrite:
            return "The remote application wants to replace your device clipboard."
        }
    }
}

struct TerminalViewportGeometry: Equatable {
    let widthPixels: Int
    let heightPixels: Int
    let columns: Int
    let rows: Int
    let snappedWidthPixels: Int
    let snappedHeightPixels: Int
    let displayScale: CGFloat

    init?(
        bounds: CGSize,
        displayScale: CGFloat,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) {
        guard bounds.width > 0,
              bounds.height > 0,
              displayScale > 0,
              cellWidthPixels > 0,
              cellHeightPixels > 0 else {
            return nil
        }

        let widthPixels = max(1, Int((bounds.width * displayScale).rounded(.down)))
        let heightPixels = max(1, Int((bounds.height * displayScale).rounded(.down)))
        let columns = max(1, widthPixels / cellWidthPixels)
        let rows = max(1, heightPixels / cellHeightPixels)

        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.columns = columns
        self.rows = rows
        self.snappedWidthPixels = min(widthPixels, columns * cellWidthPixels)
        self.snappedHeightPixels = min(heightPixels, rows * cellHeightPixels)
        self.displayScale = displayScale
    }

    var snappedSize: CGSize {
        CGSize(
            width: CGFloat(snappedWidthPixels) / displayScale,
            height: CGFloat(snappedHeightPixels) / displayScale
        )
    }
}

enum TerminalKeyboardGeometry {
    static func overlapHeight(viewFrame: CGRect, keyboardFrame: CGRect) -> CGFloat {
        guard !viewFrame.isEmpty, !keyboardFrame.isEmpty else { return 0 }

        let intersection = viewFrame.intersection(keyboardFrame)
        guard !intersection.isNull,
              intersection.maxY >= viewFrame.maxY - 1 else {
            return 0
        }

        return intersection.height
    }
}
