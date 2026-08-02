import SwiftUI
import UIKit

typealias ToolbarButtonAction = ([UInt8]) -> Void

enum ClipboardAction: Equatable {
    case copy
    case paste
}

/// UIKit host for the keyboard toolbar, mounted as `inputAccessoryView` on the terminal's
/// hidden `UITextField`.
///
/// Manages sticky modifier state (Ctrl, Opt, Shift) and translates toolbar button taps
/// into byte sequences sent to the active terminal session. Modifier encoding follows
/// xterm conventions: escape sequences get `;{code}` inserted, single bytes get
/// Ctrl masking / Shift casing / Opt ESC-prefixing.
class KeyboardToolbarAccessoryView: UIView {
    static let preferredHeight: CGFloat = 44
    static let buttonVisualHeight: CGFloat = 36

    private var hostingController: UIHostingController<KeyboardToolbarContent>?

    // Active sticky modifiers (Ctrl, Opt, Shift) — applied to next key press
    private(set) var activeModifiers: Set<String> = []

    // Callback that sends bytes to the terminal session
    var onButtonTap: ToolbarButtonAction?

    // Callback to present the edit sheet
    var onEditTap: (() -> Void)?

    // Callback for semantic clipboard actions
    var onClipboardAction: ((ClipboardAction) -> Void)?

    // Callback to open the explicit on-device dictation composer.
    var onVoicePrompt: (() -> Void)?

    // Callback to open the verified SSH/SFTP file transfer sheet.
    var onFileUpload: (() -> Void)?

    // Current button layout
    private(set) var buttons: [ToolbarButton]
    private(set) var selectionAvailable = false
    private(set) var pasteAvailable = TerminalPasteboard.shared.hasStrings
    private(set) var voicePromptAvailable = VoicePromptSettings.shared.isEnabled
    private var pasteboardObserver: NSObjectProtocol?

    init(buttons: [ToolbarButton]? = nil) {
        self.buttons = buttons ?? ToolbarConfigurationService.shared.loadButtons()
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.preferredHeight))
        autoresizingMask = .flexibleWidth
        setupHostingController()

        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: TerminalPasteboard.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPasteAvailability()
        }
    }

    deinit {
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Reload buttons from persistence (after edit)
    func reloadButtons() {
        let updatedButtons = ToolbarConfigurationService.shared.loadButtons()
        guard updatedButtons != buttons else {
            refreshPasteAvailability()
            return
        }

        buttons = updatedButtons
        activeModifiers.formIntersection(Set(updatedButtons.map(\.id)))
        updateContent()
    }

    func setSelectionAvailable(_ available: Bool) {
        guard available != selectionAvailable else { return }
        selectionAvailable = available
        updateContent()
    }

    func setPasteAvailable(_ available: Bool) {
        guard available != pasteAvailable else { return }
        pasteAvailable = available
        updateContent()
    }

    func setVoicePromptAvailable(_ available: Bool) {
        guard available != voicePromptAvailable else { return }
        voicePromptAvailable = available
        updateContent()
    }

    var displayedButtons: [ToolbarButton] {
        guard selectionAvailable,
              !buttons.contains(where: { $0.id == ToolbarButton.copy.id }) else {
            return buttons
        }

        var result = buttons
        result.insert(.copy, at: result.startIndex)
        return result
    }

    private func refreshPasteAvailability() {
        setPasteAvailable(TerminalPasteboard.shared.hasStrings)
    }

    private func setupHostingController() {
        let content = makeContent()
        let hosting = UIHostingController(rootView: content)
        hosting.safeAreaRegions = []
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        hostingController = hosting
    }

    private func updateContent() {
        hostingController?.rootView = makeContent()
    }

    private func makeContent() -> KeyboardToolbarContent {
        KeyboardToolbarContent(
            buttons: displayedButtons,
            activeModifiers: activeModifiers,
            selectionAvailable: selectionAvailable,
            pasteAvailable: pasteAvailable,
            voicePromptAvailable: voicePromptAvailable,
            onButtonTap: { [weak self] button in
                self?.handleButtonTap(button)
            },
            onSwipeArrow: { [weak self] bytes in
                self?.onButtonTap?(bytes)
            },
            onEditTap: { [weak self] in
                self?.onEditTap?()
            }
        )
    }

    func handleButtonTap(_ button: ToolbarButton) {
        if button.id == ToolbarButton.copy.id {
            guard selectionAvailable else { return }
            HapticService.lightTap()
            onClipboardAction?(.copy)
            return
        }

        if button.id == ToolbarButton.paste.id {
            guard pasteAvailable else { return }
            HapticService.lightTap()
            onClipboardAction?(.paste)
            return
        }

        if button.id == ToolbarButton.voicePrompt.id {
            guard voicePromptAvailable else { return }
            HapticService.lightTap()
            onVoicePrompt?()
            return
        }

        if button.id == ToolbarButton.uploadFile.id {
            HapticService.lightTap()
            onFileUpload?()
            return
        }

        // Sticky modifiers toggle on/off and modify the next key press
        if ToolbarButton.stickyModifierIDs.contains(button.id) {
            if activeModifiers.contains(button.id) {
                activeModifiers.remove(button.id)
            } else {
                activeModifiers.insert(button.id)
            }
            HapticService.selection()
            updateContent()
            return
        }

        HapticService.lightTap()
        let modified = applyModifiersIfNeeded(to: ArraySlice(button.bytes))
        onButtonTap?(Array(modified))
    }

    // Applies any active sticky modifiers to the given input bytes.
    // Two code paths: escape sequences (arrows, function keys) and single printable bytes.
    func applyModifiersIfNeeded(to data: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard !activeModifiers.isEmpty else { return data }
        defer {
            activeModifiers.removeAll()
            updateContent()
        }

        let hasShift = activeModifiers.contains("shift")
        let hasCtrl = activeModifiers.contains("ctrl")
        let hasOpt = activeModifiers.contains("opt")

        // Path A — Escape sequences from toolbar buttons (arrows, function keys, etc.)
        if data.count > 1, data.first == 0x1B {
            let modCode = 1 + (hasShift ? 1 : 0) + (hasOpt ? 2 : 0) + (hasCtrl ? 4 : 0)
            var result: [UInt8]
            if modCode > 1 {
                result = insertXtermModifier(into: Array(data), code: modCode)
            } else {
                result = Array(data)
            }
            return ArraySlice(result)
        }

        // Path B — Single printable byte (regular characters from keyboard/toolbar)
        var result = data

        // Ctrl: byte & 0x1F (ASCII 0x40-0x7F)
        if hasCtrl, result.count == 1, let byte = result.first, byte >= 0x40, byte <= 0x7F {
            result = ArraySlice([byte & 0x1F])
        }

        // Shift: uppercase (lowercase a-z → uppercase A-Z)
        if hasShift, result.count == 1, let byte = result.first, byte >= 0x61, byte <= 0x7A {
            result = ArraySlice([byte ^ 0x20])
        }

        // Opt: prepend ESC
        if hasOpt {
            var prefixed: [UInt8] = [0x1B]
            prefixed.append(contentsOf: result)
            result = ArraySlice(prefixed)
        }

        return result
    }

    // Insert ";{code}" into xterm escape sequences for modifier encoding
    // ESC[A → ESC[1;2A    ESC[15~ → ESC[15;2~    ESCOP → ESC[1;2P
    private func insertXtermModifier(into seq: [UInt8], code: Int) -> [UInt8] {
        let codeStr = Array(";\(code)".utf8)

        // SS3 format (ESC O x) → convert to CSI with parameter 1
        if seq.count == 3, seq[0] == 0x1B, seq[1] == 0x4F {
            return [0x1B, 0x5B, 0x31] + codeStr + [seq[2]]
        }

        // CSI format (ESC [ ... final_char)
        if seq.count >= 3, seq[0] == 0x1B, seq[1] == 0x5B {
            let final = seq.last!
            let params = Array(seq[2..<(seq.count - 1)])

            if params.isEmpty {
                // ESC[A → ESC[1;{code}A
                return [0x1B, 0x5B, 0x31] + codeStr + [final]
            } else {
                // ESC[15~ → ESC[15;{code}~
                return [0x1B, 0x5B] + params + codeStr + [final]
            }
        }

        // Unknown format, pass through
        return seq
    }

    // Required for inputAccessoryView sizing
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }
}

// MARK: - SwiftUI content for the toolbar

struct KeyboardToolbarContent: View {
    let buttons: [ToolbarButton]
    let activeModifiers: Set<String>
    let selectionAvailable: Bool
    let pasteAvailable: Bool
    let voicePromptAvailable: Bool
    let onButtonTap: (ToolbarButton) -> Void
    let onSwipeArrow: ([UInt8]) -> Void
    let onEditTap: () -> Void

    // Arrow key bytes for swipe gestures
    private static let arrowUp:    [UInt8] = [0x1B, 0x5B, 0x41]
    private static let arrowDown:  [UInt8] = [0x1B, 0x5B, 0x42]
    private static let arrowRight: [UInt8] = [0x1B, 0x5B, 0x43]
    private static let arrowLeft:  [UInt8] = [0x1B, 0x5B, 0x44]

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable button row
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(buttons) { button in
                        if ToolbarButton.swipeButtonIDs.contains(button.id) {
                            swipeButton(button)
                        } else {
                            toolbarButton(button)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)

            // Edit button (gear icon) pinned to trailing edge
            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Button(action: onEditTap) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: KeyboardToolbarAccessoryView.buttonVisualHeight,
                           height: KeyboardToolbarAccessoryView.buttonVisualHeight)
            }
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .accessibilityLabel("Customize keyboard toolbar")
        }
        .frame(height: KeyboardToolbarAccessoryView.preferredHeight)
        .background(SwiftUI.Color(AppearanceSettings.shared.currentTheme.chromeSurface))
    }

    @ViewBuilder
    private func toolbarButton(_ button: ToolbarButton) -> some View {
        let isModifier = ToolbarButton.stickyModifierIDs.contains(button.id)
        let isHighlighted = isModifier && activeModifiers.contains(button.id)
        let isEnabled = switch button.id {
        case ToolbarButton.copy.id: selectionAvailable
        case ToolbarButton.paste.id: pasteAvailable
        case ToolbarButton.voicePrompt.id: voicePromptAvailable
        default: true
        }

        Button {
            onButtonTap(button)
        } label: {
            Group {
                if button.id == ToolbarButton.voicePrompt.id {
                    Image(systemName: "mic.fill")
                } else if button.id == ToolbarButton.uploadFile.id {
                    Image(systemName: "paperclip")
                } else {
                    Text(button.label)
                }
            }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isHighlighted
                    ? SwiftUI.Color(AppearanceSettings.shared.currentTheme.background)
                    : SwiftUI.Color(AppearanceSettings.shared.currentTheme.foreground))
                .frame(minWidth: KeyboardToolbarAccessoryView.buttonVisualHeight,
                       minHeight: KeyboardToolbarAccessoryView.buttonVisualHeight)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHighlighted
                            ? SwiftUI.Color(AppearanceSettings.shared.currentTheme.foreground)
                            : SwiftUI.Color(AppearanceSettings.shared.currentTheme.cardSurface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(SwiftUI.Color(AppearanceSettings.shared.currentTheme.separator), lineWidth: 0.5)
                )
                // Scale bounce on modifier toggle
                .scaleEffect(isHighlighted ? 1.06 : 1.0)
                .animation(.spring(duration: 0.15, bounce: 0.4), value: isHighlighted)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .disabled(!isEnabled)
        .accessibilityLabel(button.accessibilityLabel)
        .accessibilityValue(isModifier ? (isHighlighted ? "Active" : "Inactive") : "")
        .accessibilityHint(isModifier ? "Applies to the next key" : "")
        .accessibilityIdentifier(button.id == ToolbarButton.voicePrompt.id ? "terminal.toolbar.voice" : "terminal.toolbar.\(button.id)")
    }

    // Swipe button — drag to send arrow keys, with accumulated distance tracking
    @ViewBuilder
    private func swipeButton(_ button: ToolbarButton) -> some View {
        SwipeArrowButton(
            label: button.label,
            buttonID: button.id,
            onArrow: onSwipeArrow
        )
    }
}

// MARK: - Swipe arrow button with drag gesture

private struct SwipeArrowButton: View {
    let label: String
    let buttonID: String
    let onArrow: ([UInt8]) -> Void

    // Track accumulated drag distance to fire arrow keys at intervals
    @State private var lastStepX: CGFloat = 0
    @State private var lastStepY: CGFloat = 0
    @State private var isDragging = false

    // Points of drag per arrow key event
    private let stepSize: CGFloat = 20

    private let arrowUp:    [UInt8] = [0x1B, 0x5B, 0x41]
    private let arrowDown:  [UInt8] = [0x1B, 0x5B, 0x42]
    private let arrowRight: [UInt8] = [0x1B, 0x5B, 0x43]
    private let arrowLeft:  [UInt8] = [0x1B, 0x5B, 0x44]

    private var allowHorizontal: Bool { buttonID != "swipe-vert" }
    private var allowVertical: Bool { buttonID != "swipe-horiz" }

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(isDragging
                ? SwiftUI.Color(AppearanceSettings.shared.currentTheme.background)
                : SwiftUI.Color(AppearanceSettings.shared.currentTheme.foreground))
            .frame(width: 44, height: KeyboardToolbarAccessoryView.buttonVisualHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isDragging
                        ? SwiftUI.Color(AppearanceSettings.shared.currentTheme.foreground)
                        : SwiftUI.Color(AppearanceSettings.shared.currentTheme.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(SwiftUI.Color(AppearanceSettings.shared.currentTheme.separator), lineWidth: 0.5)
            )
            .frame(minHeight: 44)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        isDragging = true
                        let dx = value.translation.width
                        let dy = value.translation.height

                        // Horizontal arrow keys
                        if allowHorizontal {
                            while dx - lastStepX > stepSize {
                                lastStepX += stepSize
                                HapticService.lightTap()
                                onArrow(arrowRight)
                            }
                            while lastStepX - dx > stepSize {
                                lastStepX -= stepSize
                                HapticService.lightTap()
                                onArrow(arrowLeft)
                            }
                        }

                        // Vertical arrow keys
                        if allowVertical {
                            while dy - lastStepY > stepSize {
                                lastStepY += stepSize
                                HapticService.lightTap()
                                onArrow(arrowDown)
                            }
                            while lastStepY - dy > stepSize {
                                lastStepY -= stepSize
                                HapticService.lightTap()
                                onArrow(arrowUp)
                            }
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastStepX = 0
                        lastStepY = 0
                    }
            )
            .accessibilityLabel(ToolbarButton.allAvailable.first(where: { $0.id == buttonID })?.accessibilityLabel ?? label)
    }
}
