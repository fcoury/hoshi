import SwiftUI
import UIKit

typealias ToolbarButtonAction = ([UInt8]) -> Void

/// UIKit host for the keyboard toolbar, mounted as `inputAccessoryView` on the terminal's
/// hidden `UITextField`.
///
/// Manages sticky modifier state (Ctrl, Opt, Shift) and translates toolbar button taps
/// into byte sequences sent to the active terminal session. Modifier encoding follows
/// xterm conventions: escape sequences get `;{code}` inserted, single bytes get
/// Ctrl masking / Shift casing / Opt ESC-prefixing.
class KeyboardToolbarAccessoryView: UIView {
    private var hostingController: UIHostingController<KeyboardToolbarContent>?

    // Active sticky modifiers (Ctrl, Opt, Shift) — applied to next key press
    private var activeModifiers: Set<String> = []

    // Callback that sends bytes to the terminal session
    var onButtonTap: ToolbarButtonAction?

    // Callback to present the edit sheet
    var onEditTap: (() -> Void)?

    // Current button layout
    private var buttons: [ToolbarButton]

    init() {
        self.buttons = ToolbarConfigurationService.shared.loadButtons()
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        autoresizingMask = .flexibleWidth
        setupHostingController()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Reload buttons from persistence (after edit)
    func reloadButtons() {
        buttons = ToolbarConfigurationService.shared.loadButtons()
        activeModifiers.removeAll()
        updateContent()
    }

    private func setupHostingController() {
        let content = makeContent()
        let hosting = UIHostingController(rootView: content)
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
            buttons: buttons,
            activeModifiers: activeModifiers,
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

    private func handleButtonTap(_ button: ToolbarButton) {
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
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }
}

// MARK: - SwiftUI content for the toolbar

struct KeyboardToolbarContent: View {
    let buttons: [ToolbarButton]
    let activeModifiers: Set<String>
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(buttons) { button in
                        if ToolbarButton.swipeButtonIDs.contains(button.id) {
                            swipeButton(button)
                        } else {
                            toolbarButton(button)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // Edit button (gear icon) pinned to trailing edge
            Divider()
                .frame(height: 24)
                .padding(.horizontal, 4)

            Button(action: onEditTap) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 44)
        .background(SwiftUI.Color(AppearanceSettings.shared.currentTheme.chromeSurface))
    }

    @ViewBuilder
    private func toolbarButton(_ button: ToolbarButton) -> some View {
        let isModifier = ToolbarButton.stickyModifierIDs.contains(button.id)
        let isHighlighted = isModifier && activeModifiers.contains(button.id)

        Button {
            onButtonTap(button)
        } label: {
            Text(button.label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(isHighlighted ? SwiftUI.Color.black : SwiftUI.Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted ? SwiftUI.Color.white : SwiftUI.Color(AppearanceSettings.shared.currentTheme.cardSurface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SwiftUI.Color(AppearanceSettings.shared.currentTheme.separator), lineWidth: 0.5)
                )
                // Scale bounce on modifier toggle
                .scaleEffect(isHighlighted ? 1.1 : 1.0)
                .animation(.spring(duration: 0.15, bounce: 0.4), value: isHighlighted)
        }
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
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(isDragging ? SwiftUI.Color.black : SwiftUI.Color.primary)
            .frame(width: 50)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDragging ? SwiftUI.Color.white : SwiftUI.Color(AppearanceSettings.shared.currentTheme.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SwiftUI.Color(AppearanceSettings.shared.currentTheme.separator), lineWidth: 0.5)
            )
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
    }
}
