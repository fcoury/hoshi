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

/// View-space geometry of the current terminal selection.
///
/// Ghostty reports the selection's corners as the left edge of the first cell
/// and the right edge of the last cell, but vertically at the text *baseline*
/// of the first and last rows rather than at their top and bottom edges. This
/// type snaps those baselines back onto row boundaries so handles and the edit
/// menu line up with the highlighted cells.
struct TerminalSelectionGeometry: Equatable {
    /// Ghostty's default `window-padding-y` top inset, which Hoshi does not override.
    static let defaultGridPaddingTop: CGFloat = 2

    /// Left edge of the first selected cell, at the top of its row.
    let startAnchor: CGPoint
    /// Right edge of the last selected cell, at the bottom of its row.
    let endAnchor: CGPoint
    /// A point inside the first selected cell that Ghostty keeps selected when
    /// it is used as the click origin of a right-to-left drag.
    let startPressPoint: CGPoint
    /// A point inside the last selected cell that Ghostty keeps selected when
    /// it is used as the click origin of a left-to-right drag.
    let endPressPoint: CGPoint
    let rect: CGRect
    let cellSize: CGSize

    init?(
        topLeft: CGPoint,
        bottomRight: CGPoint,
        cellWidthPixels: CGFloat,
        cellHeightPixels: CGFloat,
        displayScale: CGFloat,
        renderOrigin: CGPoint,
        gridPaddingTop: CGFloat = TerminalSelectionGeometry.defaultGridPaddingTop
    ) {
        guard topLeft.x.isFinite,
              topLeft.y.isFinite,
              bottomRight.x.isFinite,
              bottomRight.y.isFinite,
              topLeft.x >= 0,
              topLeft.y >= 0,
              bottomRight.x >= 0,
              bottomRight.y >= 0,
              cellWidthPixels > 0,
              cellHeightPixels > 0,
              displayScale > 0 else {
            return nil
        }

        // Ghostty's text viewport coordinates are already logical points.
        // Only the cell metrics remain in framebuffer pixels.
        let cellWidth = cellWidthPixels / displayScale
        let cellHeight = cellHeightPixels / displayScale

        // A baseline always sits strictly inside its row, so flooring the
        // padding-relative baseline yields that row's index.
        func rowIndex(forBaseline y: CGFloat) -> CGFloat {
            max(0, ((y - gridPaddingTop) / cellHeight).rounded(.down))
        }
        let topRowTop = gridPaddingTop + rowIndex(forBaseline: topLeft.y) * cellHeight
        let bottomRowBottom = gridPaddingTop + (rowIndex(forBaseline: bottomRight.y) + 1) * cellHeight

        let startAnchor = CGPoint(x: topLeft.x + renderOrigin.x, y: topRowTop + renderOrigin.y)
        let endAnchor = CGPoint(x: bottomRight.x + renderOrigin.x, y: bottomRowBottom + renderOrigin.y)

        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
        // Ghostty includes the clicked cell when the click lands on the far
        // side of a 60% threshold relative to the drag direction, so press
        // near the outer edge of each end cell.
        self.startPressPoint = CGPoint(
            x: startAnchor.x + cellWidth * 0.1,
            y: startAnchor.y + cellHeight / 2
        )
        self.endPressPoint = CGPoint(
            x: endAnchor.x - cellWidth * 0.1,
            y: endAnchor.y - cellHeight / 2
        )
        self.cellSize = CGSize(width: cellWidth, height: cellHeight)
        self.rect = CGRect(
            x: min(startAnchor.x, endAnchor.x),
            y: startAnchor.y,
            width: max(1, abs(endAnchor.x - startAnchor.x)),
            height: max(cellHeight, endAnchor.y - startAnchor.y)
        )
    }
}

/// Synthetic mouse presses that keep Ghostty's multi-click detection predictable.
///
/// Ghostty counts a press as a double or triple click when it lands within one
/// cell width of the previous press inside its click-repeat interval. Gesture
/// code that synthesizes presses at a remembered point would otherwise flip the
/// selection between character, word and line granularity.
enum TerminalClickSequence {
    /// A point at least two cells away from `point`, inside a surface of `size`.
    /// Pressing there first guarantees the next press at `point` starts a fresh
    /// single click.
    static func resetPoint(awayFrom point: CGPoint, cellSize: CGSize, surfaceSize: CGSize) -> CGPoint {
        let horizontal = cellSize.width * 2
        if point.x + horizontal <= surfaceSize.width {
            return CGPoint(x: point.x + horizontal, y: point.y)
        }
        if point.x - horizontal >= 0 {
            return CGPoint(x: point.x - horizontal, y: point.y)
        }

        let vertical = cellSize.height * 2
        let y = point.y + vertical <= surfaceSize.height ? point.y + vertical : max(0, point.y - vertical)
        return CGPoint(x: point.x, y: y)
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

// MARK: - System keyboard text input document

/// The tiny document the terminal surface presents to the iOS text system.
///
/// A terminal has no locally editable text: every keystroke goes straight to
/// the remote PTY. A view that only adopts `UIKeyInput` gets a single
/// `deleteBackward()` per backspace press, though, because the system keyboard
/// only auto-repeats delete for documents it can inspect through `UITextInput`.
/// This document gives the keyboard a stable, non-empty context: one invisible
/// placeholder before the caret (so there is always something to delete),
/// followed by any IME composition in progress. Offsets are UTF-16 code units
/// to match `NSRange`.
struct TerminalTextInputDocument: Equatable {
    /// A zero-width space: non-empty for the keyboard, but neither a letter
    /// nor a Unicode White_Space character, so it cannot feed the double-space
    /// period shortcut or autocapitalization. (Foundation's
    /// `CharacterSet.whitespaces` does include it; the keyboard was verified
    /// on device not to insert a period after two spaces.)
    static let placeholder = "\u{200B}"
    static let placeholderLength = (placeholder as NSString).length

    private(set) var markedText = ""
    /// Selection inside `markedText`, relative to its start.
    private(set) var markedSelection = NSRange(location: 0, length: 0)

    var text: String { Self.placeholder + markedText }
    var length: Int { (text as NSString).length }
    var hasMarkedText: Bool { !markedText.isEmpty }

    /// The range of the composition in document offsets, or `nil` when idle.
    var markedRange: NSRange? {
        hasMarkedText
            ? NSRange(location: Self.placeholderLength, length: (markedText as NSString).length)
            : nil
    }

    /// The caret sits at the end of the document unless the IME has placed a
    /// selection inside its composition.
    var selectedRange: NSRange {
        guard hasMarkedText else { return NSRange(location: length, length: 0) }
        return NSRange(
            location: Self.placeholderLength + markedSelection.location,
            length: markedSelection.length
        )
    }

    func text(in range: NSRange) -> String {
        let clamped = clamp(range)
        return (text as NSString).substring(with: clamped)
    }

    func clamp(_ range: NSRange) -> NSRange {
        let location = min(max(0, range.location), length)
        let end = min(max(location, range.location + range.length), length)
        return NSRange(location: location, length: end - location)
    }

    /// Replaces the composition. An empty or `nil` string ends it without
    /// committing anything.
    mutating func setMarkedText(_ newText: String?, selectedRange: NSRange) {
        markedText = newText ?? ""
        let markedLength = (markedText as NSString).length
        let location = min(max(0, selectedRange.location), markedLength)
        let selectionLength = min(max(0, selectedRange.length), markedLength - location)
        markedSelection = NSRange(location: location, length: selectionLength)
    }

    /// Ends the composition and returns the text that should be sent to the
    /// terminal.
    mutating func commitMarkedText() -> String {
        let committed = markedText
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        return committed
    }

    /// Removes the composition's last composed character. Returns `false`
    /// when there is no composition, meaning the delete belongs to the PTY.
    mutating func deleteBackwardInMarkedText() -> Bool {
        guard hasMarkedText else { return false }
        markedText.removeLast()
        let markedLength = (markedText as NSString).length
        markedSelection = NSRange(location: markedLength, length: 0)
        return true
    }
}

final class TerminalTextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

final class TerminalTextRange: UITextRange {
    let range: NSRange

    init(_ range: NSRange) {
        self.range = range
    }

    override var start: UITextPosition { TerminalTextPosition(range.location) }
    override var end: UITextPosition { TerminalTextPosition(range.location + range.length) }
    override var isEmpty: Bool { range.length == 0 }
}
