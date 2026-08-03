import Foundation
import CoreGraphics
import UIKit

/// Keeps terminal clipboard access injectable so tests never touch the user's system pasteboard.
@MainActor
enum TerminalPasteboard {
    static var shared: UIPasteboard = .general
}

struct TerminalRemoteClipboardPolicy: Equatable, Sendable {
    var read: RemoteClipboardAccessPolicy = .ask
    var write: RemoteClipboardAccessPolicy = .ask
    var serverName: String = "Remote server"
    var endpoint: String?

    @MainActor
    static func forServer(_ server: Server?) -> Self {
        guard let server else { return Self() }
        return Self(
            read: server.remoteClipboardReadPolicy,
            write: server.remoteClipboardWritePolicy,
            serverName: server.name,
            endpoint: server.endpoint
        )
    }
}

enum TerminalClipboardPayloadError: Error, Equatable {
    case tooLarge(byteCount: Int)
    case invalidUTF8
}

enum TerminalClipboardPayload {
    static let maximumBytes = 64 * 1_024

    static func decodeCString(
        _ pointer: UnsafePointer<CChar>,
        maximumBytes: Int = maximumBytes
    ) -> Result<String, TerminalClipboardPayloadError> {
        let byteCount = strnlen(pointer, maximumBytes + 1)
        guard byteCount <= maximumBytes else {
            return .failure(.tooLarge(byteCount: byteCount))
        }

        let bytes = Data(bytes: pointer, count: byteCount)
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .failure(.invalidUTF8)
        }
        return .success(text)
    }

    static func validate(_ content: String) -> Result<String, TerminalClipboardPayloadError> {
        let byteCount = content.utf8.count
        guard byteCount <= maximumBytes else {
            return .failure(.tooLarge(byteCount: byteCount))
        }
        return .success(content)
    }
}

enum TerminalClipboardNoticeKind: Equatable {
    case readAllowed
    case readDenied
    case writeAllowed
    case writeDenied
    case payloadTooLarge
    case invalidPayload

    var isWarning: Bool {
        switch self {
        case .readAllowed, .writeAllowed: false
        case .readDenied, .writeDenied, .payloadTooLarge, .invalidPayload: true
        }
    }

    var symbolName: String {
        switch self {
        case .readAllowed: "doc.on.clipboard"
        case .writeAllowed: "clipboard"
        case .readDenied, .writeDenied: "hand.raised"
        case .payloadTooLarge, .invalidPayload: "exclamationmark.shield"
        }
    }
}

struct TerminalClipboardNotice: Identifiable, Equatable {
    let id = UUID()
    let kind: TerminalClipboardNoticeKind
    let serverName: String
    let byteCount: Int?

    var message: String {
        switch kind {
        case .readAllowed:
            return "Shared device clipboard with \(serverName)"
        case .readDenied:
            return "Blocked clipboard read from \(serverName)"
        case .writeAllowed:
            return "Copied from \(serverName) to device clipboard"
        case .writeDenied:
            return "Blocked clipboard change from \(serverName)"
        case .payloadTooLarge:
            return "Blocked clipboard data larger than \(TerminalClipboardPayload.maximumBytes.formatted()) bytes"
        case .invalidPayload:
            return "Blocked invalid clipboard data from \(serverName)"
        }
    }
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
    let id: UUID
    let content: String
    let kind: TerminalClipboardRequestKind
    let assessment: TerminalPasteAssessment
    let serverName: String?
    let endpoint: String?
    let onDecision: @MainActor (Bool) -> Void

    init(
        id: UUID = UUID(),
        content: String,
        kind: TerminalClipboardRequestKind,
        assessment: TerminalPasteAssessment,
        serverName: String? = nil,
        endpoint: String? = nil,
        onDecision: @escaping @MainActor (Bool) -> Void
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.assessment = assessment
        self.serverName = serverName
        self.endpoint = endpoint
        self.onDecision = onDecision
    }

    var message: String {
        switch kind {
        case .paste:
            return assessment.confirmationMessage
        case .remoteRead:
            let destination = endpoint ?? serverName ?? "the remote server"
            return "Allow \(destination) to read your device clipboard? \(assessment.byteCount.formatted()) bytes will be sent. Clipboard contents are not shown."
        case .remoteWrite:
            let source = endpoint ?? serverName ?? "the remote server"
            return "Allow \(source) to replace your device clipboard? The remote application is sending \(assessment.byteCount.formatted()) bytes. Clipboard contents are not shown."
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

    /// Pixel-aligned origin that balances incomplete-cell space across both edges.
    var centeredOrigin: CGPoint {
        CGPoint(
            x: CGFloat((widthPixels - snappedWidthPixels) / 2) / displayScale,
            y: CGFloat((heightPixels - snappedHeightPixels) / 2) / displayScale
        )
    }

    var centeredFrame: CGRect {
        CGRect(origin: centeredOrigin, size: snappedSize)
    }
}

struct TerminalSelectionGeometry: Equatable {
    let startAnchor: CGPoint
    let endAnchor: CGPoint
    let rect: CGRect

    init?(
        topLeft: CGPoint,
        bottomRight: CGPoint,
        cellHeightPixels: CGFloat,
        displayScale: CGFloat,
        renderOrigin: CGPoint
    ) {
        guard topLeft.x.isFinite,
              topLeft.y.isFinite,
              bottomRight.x.isFinite,
              bottomRight.y.isFinite,
              topLeft.x >= 0,
              topLeft.y >= 0,
              bottomRight.x >= 0,
              bottomRight.y >= 0,
              cellHeightPixels > 0,
              displayScale > 0 else {
            return nil
        }

        // Ghostty's text viewport coordinates are already logical points.
        // Only the cell metrics remain in framebuffer pixels.
        let startAnchor = CGPoint(
            x: topLeft.x + renderOrigin.x,
            y: topLeft.y + renderOrigin.y
        )
        let endAnchor = CGPoint(
            x: bottomRight.x + renderOrigin.x,
            y: bottomRight.y + renderOrigin.y
        )
        let cellHeight = cellHeightPixels / displayScale

        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
        self.rect = CGRect(
            x: min(startAnchor.x, endAnchor.x),
            y: min(startAnchor.y, endAnchor.y),
            width: max(1, abs(endAnchor.x - startAnchor.x)),
            height: max(cellHeight, abs(endAnchor.y - startAnchor.y) + cellHeight)
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

enum TerminalApplicationLifecycle {
    static func shouldRecordKeyboardDismissal(applicationState: UIApplication.State) -> Bool {
        applicationState == .active
    }
}
