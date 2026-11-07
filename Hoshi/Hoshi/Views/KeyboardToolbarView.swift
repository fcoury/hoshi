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
    private static let arrowKeyIDs: Set<String> = [
        ToolbarButton.arrowUp.id, ToolbarButton.arrowDown.id,
        ToolbarButton.arrowLeft.id, ToolbarButton.arrowRight.id,
    ]

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

    // Callback to dismiss the software keyboard from the toolbar.
    var onDismissKeyboard: (() -> Void)?

    // Callback when the user picks a key set (nil = automatic).
    var onSelectProfile: ((String?) -> Void)?

    private(set) var profileChip: KeyProfileChip?

    // Current button layout
    private(set) var buttons: [ToolbarButton]
    private(set) var selectionAvailable = false
    private(set) var pasteAvailable = TerminalPasteboard.shared.hasStrings
    private(set) var voicePromptAvailable = VoicePromptSettings.shared.isEnabled
    private var pasteboardObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    init(buttons: [ToolbarButton]? = nil) {
        self.buttons = buttons ?? KeyProfileStore.shared.shell.resolvedKeys
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

        // UIPasteboard.changedNotification only reports changes made inside
        // Hoshi, so recheck after the user copies something in another app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPasteAvailability()
        }
    }

    deinit {
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Reload buttons from persistence (after edit)
    /// Key sets are pushed through `apply(profile:chip:)`; this only refreshes
    /// clipboard state after the editor closes.
    func reloadButtons() {
        refreshPasteAvailability()
    }

    /// Shows the given key set's keys and the chip describing the selection.
    func apply(buttons updatedButtons: [ToolbarButton], chip: KeyProfileChip?) {
        guard updatedButtons != buttons || chip != profileChip else { return }
        if updatedButtons != buttons {
            buttons = updatedButtons
            activeModifiers.formIntersection(Set(updatedButtons.map(\.id)))
        }
        profileChip = chip
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
        buttons
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
            },
            onDismissKeyboard: { [weak self] in
                HapticService.lightTap()
                self?.onDismissKeyboard?()
            },
            profileChip: profileChip,
            onSelectProfile: { [weak self] profileID in
                HapticService.selection()
                self?.onSelectProfile?(profileID)
            }
        )
    }

    func handleButtonTap(_ button: ToolbarButton) {
        if Self.arrowKeyIDs.contains(button.id) {
            ToolbarTips.recordArrowKeyTap()
        }

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
        return apply(modifiers: activeModifiers, to: data)
    }

    /// Takes the sticky modifiers for a gesture that sends many keys, so each key
    /// gets them (e.g. Opt + arrow drag jumps word by word), not just the first.
    func takeActiveModifiers() -> Set<String> {
        let modifiers = activeModifiers
        if !modifiers.isEmpty {
            activeModifiers.removeAll()
            updateContent()
        }
        return modifiers
    }

    func apply(modifiers: Set<String>, to data: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard !modifiers.isEmpty else { return data }
        let hasShift = modifiers.contains("shift")
        let hasCtrl = modifiers.contains("ctrl")
        let hasOpt = modifiers.contains("opt")

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

/// What the toolbar shows about the active key set and its alternatives.
struct KeyProfileChip: Equatable {
    struct Option: Equatable, Identifiable {
        let id: String
        let name: String
        let symbol: String
    }

    let activeID: String
    let activeName: String
    let activeSymbol: String
    /// Non-nil when the user pinned a set for this server.
    let pinnedID: String?
    let options: [Option]

    init(active: KeyProfile, pinnedID: String?, profiles: [KeyProfile]) {
        self.activeID = active.id
        self.activeName = active.name
        self.activeSymbol = active.symbol
        self.pinnedID = pinnedID
        self.options = profiles.map { Option(id: $0.id, name: $0.name, symbol: $0.symbol) }
    }
}

/// Renders a toolbar key's face: an SF Symbol when one is defined, otherwise its text label.
struct ToolbarKeyGlyph: View {
    let button: ToolbarButton

    var body: some View {
        if let symbol = button.symbolName {
            Image(systemName: symbol)
                .imageScale(.small)
        } else {
            Text(button.label)
        }
    }
}

/// Shared key styling so tap keys, swipe keys and pinned controls read as one set.
private struct ToolbarKeyFace: ViewModifier {
    let isHighlighted: Bool
    var isEnabled: Bool = true

    private var theme: TerminalTheme { AppearanceSettings.shared.currentTheme }

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(isHighlighted
                ? SwiftUI.Color(theme.background)
                : SwiftUI.Color(theme.foreground))
            .opacity(isEnabled ? 1 : 0.4)
            .frame(minWidth: KeyboardToolbarContent.keyMinWidth,
                   minHeight: KeyboardToolbarAccessoryView.buttonVisualHeight)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted
                        ? SwiftUI.Color(theme.foreground)
                        : SwiftUI.Color(theme.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(SwiftUI.Color(theme.separator), lineWidth: 0.5)
            )
    }
}

struct KeyboardToolbarContent: View {
    /// Uniform minimum key width so single-glyph keys line up into an even grid.
    static let keyMinWidth: CGFloat = 40

    let buttons: [ToolbarButton]
    let activeModifiers: Set<String>
    let selectionAvailable: Bool
    let pasteAvailable: Bool
    let voicePromptAvailable: Bool
    let onButtonTap: (ToolbarButton) -> Void
    let onSwipeArrow: ([UInt8]) -> Void
    let onEditTap: () -> Void
    let onDismissKeyboard: () -> Void
    var profileChip: KeyProfileChip? = nil
    var onSelectProfile: (String?) -> Void = { _ in }

    private var theme: TerminalTheme { AppearanceSettings.shared.currentTheme }

    var body: some View {
        HStack(spacing: 0) {
            if let chip = profileChip {
                keySetChip(chip)
                    .padding(.leading, 6)
            }

            // Scrollable button row. The trailing fade signals more keys
            // instead of clipping the last visible key mid-glyph.
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(buttons) { button in
                        if ToolbarButton.swipeButtonIDs.contains(button.id) {
                            swipeButton(button)
                        } else {
                            toolbarButton(button)
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
            }
            .scrollIndicators(.hidden)
            .mask(
                HStack(spacing: 0) {
                    SwiftUI.Color.black
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 20)
                }
            )

            hideKeyboardControl
                .padding(.trailing, 4)
        }
        .frame(height: KeyboardToolbarAccessoryView.preferredHeight)
        .background(SwiftUI.Color(theme.background))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SwiftUI.Color(theme.separator))
                .frame(height: 0.5)
        }
    }

    /// Long-press menu shared by every key: switch key sets or edit the active one.
    @ViewBuilder
    private var keySetMenuItems: some View {
        if let chip = profileChip {
            Section("Key Set: \(chip.activeName)\(chip.pinnedID == nil ? " (Automatic)" : "")") {
                Button {
                    onSelectProfile(nil)
                } label: {
                    if chip.pinnedID == nil {
                        Label("Automatic", systemImage: "checkmark")
                    } else {
                        Label("Automatic", systemImage: "wand.and.stars")
                    }
                }
                ForEach(chip.options) { option in
                    Button {
                        onSelectProfile(option.id)
                    } label: {
                        Label(option.name, systemImage: chip.pinnedID == option.id ? "checkmark" : option.symbol)
                    }
                }
            }
            Button {
                onEditTap()
            } label: {
                Label("Edit \(chip.activeName) Keys…", systemImage: "slider.horizontal.3")
            }
        }
    }

    /// The active key set's icon. Tap for the same menu a long press on any key opens;
    /// a pin badge marks a set chosen by hand instead of picked automatically.
    private func keySetChip(_ chip: KeyProfileChip) -> some View {
        Menu {
            keySetMenuItems
        } label: {
            Image(systemName: chip.activeSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SwiftUI.Color(theme.accentBlue))
                .frame(width: 36, height: KeyboardToolbarAccessoryView.buttonVisualHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SwiftUI.Color(theme.accentBlue).opacity(0.14))
                )
                .overlay(alignment: .topTrailing) {
                    if chip.pinnedID != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(SwiftUI.Color(theme.background))
                            .padding(2.5)
                            .background(Circle().fill(SwiftUI.Color(theme.accentBlue)))
                            .offset(x: 3, y: -3)
                    }
                }
                .frame(height: 44)
                .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Key set: \(chip.activeName)")
        .accessibilityValue(chip.pinnedID == nil ? "Automatic" : "Pinned")
        .accessibilityHint("Choose a key set")
        .accessibilityIdentifier("terminal.toolbar.key-set")
    }

    /// Tap hides the keyboard; holding opens the toolbar editor.
    private var hideKeyboardControl: some View {
        Image(systemName: "keyboard.chevron.compact.down")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(SwiftUI.Color(theme.secondaryForeground))
            .frame(width: 40, height: KeyboardToolbarAccessoryView.preferredHeight)
            .contentShape(.rect)
            .onTapGesture(perform: onDismissKeyboard)
            .onLongPressGesture(minimumDuration: 0.45) {
                HapticService.mediumTap()
                onEditTap()
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Hide keyboard")
            .accessibilityHint("Hold to customize the toolbar")
            .accessibilityAction(named: "Customize toolbar", onEditTap)
            .accessibilityIdentifier("terminal.toolbar.hide-keyboard")
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
            ToolbarKeyGlyph(button: button)
                .modifier(ToolbarKeyFace(isHighlighted: isHighlighted, isEnabled: isEnabled))
                // Scale bounce on modifier toggle
                .scaleEffect(isHighlighted ? 1.06 : 1.0)
                .animation(.spring(duration: 0.15, bounce: 0.4), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .disabled(!isEnabled)
        .accessibilityLabel(button.accessibilityLabel)
        .accessibilityValue(isModifier ? (isHighlighted ? "Active" : "Inactive") : "")
        .accessibilityHint(isModifier ? "Applies to the next key" : "")
        .accessibilityIdentifier(button.id == ToolbarButton.voicePrompt.id ? "terminal.toolbar.voice" : "terminal.toolbar.\(button.id)")
        .contextMenu { keySetMenuItems }
    }

    // Swipe button — drag to send arrow keys, with accumulated distance tracking
    @ViewBuilder
    private func swipeButton(_ button: ToolbarButton) -> some View {
        SwipeArrowButton(
            button: button,
            onArrow: onSwipeArrow
        )
        // No long-press menu here: hold-then-drag is how the swipe keys are used.
    }
}

// MARK: - Swipe arrow button with drag gesture

private struct SwipeArrowButton: View {
    let button: ToolbarButton
    private var buttonID: String { button.id }
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
        ToolbarKeyGlyph(button: button)
            .modifier(ToolbarKeyFace(isHighlighted: isDragging))
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
            .accessibilityLabel(button.accessibilityLabel)
    }
}
