import SwiftUI
import UIKit

// Callback when a toolbar button is tapped
typealias ToolbarButtonAction = ([UInt8]) -> Void

// UIKit host for the SwiftUI toolbar, used as inputAccessoryView
class KeyboardToolbarAccessoryView: UIView {
    private var hostingController: UIHostingController<KeyboardToolbarContent>?

    // Current Ctrl-sticky state
    private var ctrlActive = false

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
        ctrlActive = false
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
            ctrlActive: ctrlActive,
            onButtonTap: { [weak self] button in
                self?.handleButtonTap(button)
            },
            onEditTap: { [weak self] in
                self?.onEditTap?()
            }
        )
    }

    private func handleButtonTap(_ button: ToolbarButton) {
        // Ctrl is a sticky toggle — it modifies the next non-Ctrl button press
        if button.id == "ctrl" {
            ctrlActive.toggle()
            updateContent()
            return
        }

        let modified = applyCtrlModifierIfNeeded(to: ArraySlice(button.bytes))
        onButtonTap?(Array(modified))
    }

    // Applies sticky Ctrl to the next typed key (toolbar or hardware keyboard input).
    func applyCtrlModifierIfNeeded(to data: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard ctrlActive else { return data }
        defer {
            ctrlActive = false
            updateContent()
        }

        // Ctrl+letter = letter & 0x1F (works for ASCII letters and some symbols)
        guard data.count == 1, let byte = data.first, byte >= 0x40, byte <= 0x7F else {
            return data
        }

        return ArraySlice([byte & 0x1F])
    }

    // Required for inputAccessoryView sizing
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }
}

// MARK: - SwiftUI content for the toolbar

struct KeyboardToolbarContent: View {
    let buttons: [ToolbarButton]
    let ctrlActive: Bool
    let onButtonTap: (ToolbarButton) -> Void
    let onEditTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable button row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(buttons) { button in
                        toolbarButton(button)
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
        .background(SwiftUI.Color(UIColor.secondarySystemBackground))
    }

    @ViewBuilder
    private func toolbarButton(_ button: ToolbarButton) -> some View {
        let isCtrl = button.id == "ctrl"
        let isHighlighted = isCtrl && ctrlActive

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
                        .fill(isHighlighted ? SwiftUI.Color.white : SwiftUI.Color(UIColor.tertiarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SwiftUI.Color(UIColor.separator), lineWidth: 0.5)
                )
        }
    }
}
