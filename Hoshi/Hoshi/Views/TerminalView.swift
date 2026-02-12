import SwiftUI
import SwiftTerm
import CoreText

// Full terminal emulator view using SwiftTerm
// Replaces the US-001 placeholder with VT100/xterm-256color emulation
struct TerminalView: View {
    @Bindable var connectionVM: ConnectionViewModel
    @Environment(\.dismiss) private var dismiss

    // Font size state for pinch-to-zoom
    @State private var fontSize: CGFloat = 14

    // Toolbar edit sheet
    @State private var showToolbarEditor = false

    // Keyboard visibility for explicit show/hide control
    @State private var isKeyboardVisible = true

    // Server name from whichever session is active
    private var serverName: String {
        connectionVM.moshSession?.server.name
            ?? connectionVM.sshSession?.server.name
            ?? "Terminal"
    }

    private var serverDetail: String {
        let server = connectionVM.moshSession?.server ?? connectionVM.sshSession?.server
        guard let server else { return "" }
        return "\(server.username)@\(server.hostname)"
    }

    private var isMosh: Bool {
        connectionVM.moshSession != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            statusBar

            // Connection status banners
            if connectionVM.connectionState == .reconnecting {
                reconnectingBanner
            } else if connectionVM.connectionState == .disconnected && connectionVM.hasActiveSession {
                disconnectedBanner
            }

            // SwiftTerm terminal emulator
            SwiftTermView(
                connectionVM: connectionVM,
                fontSize: $fontSize,
                showToolbarEditor: $showToolbarEditor,
                keyboardVisible: $isKeyboardVisible
            )
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showToolbarEditor) {
            ToolbarEditView(onSave: {
                // SwiftTermView will detect the sheet dismissal and reload toolbar
            })
        }
    }

    private var statusBar: some View {
        HStack {
            // Connection status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(serverName)
                .font(.headline)

            Text(serverDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Mosh indicator
            if isMosh {
                Text("MOSH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            Button {
                isKeyboardVisible.toggle()
            } label: {
                Image(systemName: isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(isKeyboardVisible ? "Hide keyboard" : "Show keyboard")

            Button {
                Task {
                    await connectionVM.disconnect()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(SwiftUI.Color(TerminalTheme.chromeSurface))
    }

    private var reconnectingBanner: some View {
        HStack {
            ProgressView()
                .tint(.yellow)
            Text("Reconnecting...")
                .font(.caption)
                .foregroundStyle(.yellow)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.yellow.opacity(0.15))
    }

    private var disconnectedBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.red)
            Text("Connection lost")
                .font(.caption)
                .foregroundStyle(.red)

            Spacer()

            Button("Reconnect") {
                Task {
                    if let sshSession = connectionVM.sshSession {
                        await sshSession.reconnect()
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.15))
    }

    private var statusColor: SwiftUI.Color {
        switch connectionVM.connectionState {
        case .connected: return .green
        case .connecting, .sshBootstrap, .moshStarting: return .yellow
        case .reconnecting: return .orange
        case .disconnected: return .red
        case .error: return .red
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable wrapper

struct SwiftTermView: UIViewRepresentable {
    let connectionVM: ConnectionViewModel
    @Binding var fontSize: CGFloat
    @Binding var showToolbarEditor: Bool
    @Binding var keyboardVisible: Bool

    func makeUIView(context: Context) -> SwiftTermContainerView {
        let container = SwiftTermContainerView(
            fontSize: fontSize,
            keyboardVisible: keyboardVisible,
            coordinator: context.coordinator
        )

        // Wire the raw data callback: SSH/Mosh bytes → SwiftTerm feed
        let termView = container.terminalView
        connectionVM.setDataCallback { bytes in
            DispatchQueue.main.async {
                termView.feed(byteArray: ArraySlice(bytes))
            }
        }

        // Wire toolbar button taps → send bytes to session
        let coordinator = context.coordinator
        coordinator.inputDataTransform = { [weak container] data in
            container?.toolbarAccessory.applyCtrlModifierIfNeeded(to: data) ?? data
        }
        container.toolbarAccessory.onButtonTap = { [weak coordinator] bytes in
            guard let coordinator else { return }
            Task { @MainActor in
                await coordinator.connectionVM.sendBytes(ArraySlice(bytes))
            }
        }

        // Wire toolbar edit button → present the editor sheet
        container.toolbarAccessory.onEditTap = { [weak coordinator] in
            coordinator?.showToolbarEditorBinding?.wrappedValue = true
        }

        return container
    }

    func updateUIView(_ container: SwiftTermContainerView, context: Context) {
        // Update font size when pinch-to-zoom changes it
        if container.currentFontSize != fontSize {
            container.updateFontSize(fontSize)
        }

        // Reload toolbar buttons when the editor sheet is dismissed
        if !showToolbarEditor {
            container.toolbarAccessory.reloadButtons()
        }

        // Keep keyboard visibility in sync with the header toggle
        container.setKeyboardVisible(keyboardVisible)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            connectionVM: connectionVM,
            fontSizeBinding: $fontSize,
            showToolbarEditorBinding: $showToolbarEditor
        )
    }

    // Coordinator acts as the TerminalViewDelegate, routing user input to the session
    class Coordinator: NSObject, TerminalViewDelegate {
        let connectionVM: ConnectionViewModel
        var fontSizeBinding: Binding<CGFloat>
        var showToolbarEditorBinding: Binding<Bool>?
        var inputDataTransform: ((ArraySlice<UInt8>) -> ArraySlice<UInt8>)?

        init(connectionVM: ConnectionViewModel, fontSizeBinding: Binding<CGFloat>, showToolbarEditorBinding: Binding<Bool>? = nil) {
            self.connectionVM = connectionVM
            self.fontSizeBinding = fontSizeBinding
            self.showToolbarEditorBinding = showToolbarEditorBinding
        }

        // User typed — forward keystrokes to the active session
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let output = inputDataTransform?(data) ?? data
            Task { @MainActor in
                await connectionVM.sendBytes(output)
            }
        }

        // Terminal size changed — notify the remote PTY
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                await connectionVM.resize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            // Could update the status bar title in the future
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: SwiftTerm.TerminalView) {
            // Haptic feedback on bell
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

// MARK: - Container view that hosts SwiftTerm TerminalView with gesture support

class SwiftTermContainerView: UIView {
    let terminalView: SwiftTerm.TerminalView
    let toolbarAccessory: KeyboardToolbarAccessoryView
    private(set) var currentFontSize: CGFloat
    private weak var coordinator: SwiftTermView.Coordinator?

    // Pinch-to-zoom state
    private var pinchStartFontSize: CGFloat = 14
    private var scrollbackConfigured = false
    private(set) var isKeyboardVisible: Bool

    private var accessoryHeight: CGFloat {
        toolbarAccessory.intrinsicContentSize.height
    }

    private static var didRegisterBundledNerdFonts = false
    private static let bundledNerdFontFiles = [
        "FantasqueSansMNerdFontMono-Regular.ttf",
        "FantasqueSansMNerdFontMono-Italic.ttf",
        "FantasqueSansMNerdFontMono-Bold.ttf",
        "FantasqueSansMNerdFontMono-BoldItalic.ttf",
    ]

    private static func registerBundledNerdFontsIfNeeded() {
        guard !didRegisterBundledNerdFonts else { return }
        didRegisterBundledNerdFonts = true

        for filename in bundledNerdFontFiles {
            let fileURL = URL(fileURLWithPath: filename)
            let resource = fileURL.deletingPathExtension().lastPathComponent
            let ext = fileURL.pathExtension
            guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func terminalFont(size: CGFloat) -> UIFont {
        registerBundledNerdFontsIfNeeded()

        // PostScript names exposed by FantasqueSansM Nerd Font Mono.
        let preferredNames = [
            "FantasqueSansMNFM-Regular",
            "FantasqueSansM Nerd Font Mono Regular",
            "FantasqueSansM Nerd Font Mono",
        ]

        for name in preferredNames {
            if let font = UIFont(name: name, size: size) {
                return font
            }
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    init(fontSize: CGFloat, keyboardVisible: Bool, coordinator: SwiftTermView.Coordinator) {
        self.currentFontSize = fontSize
        self.isKeyboardVisible = keyboardVisible
        self.coordinator = coordinator

        // Create the keyboard toolbar accessory view
        toolbarAccessory = KeyboardToolbarAccessoryView()

        // Create the SwiftTerm TerminalView with a monospace font
        let font = Self.terminalFont(size: fontSize)
        terminalView = SwiftTerm.TerminalView(frame: .zero, font: font)

        super.init(frame: .zero)

        // Attach the toolbar as the terminal's input accessory view
        terminalView.inputAccessoryView = toolbarAccessory

        // Apply Nord terminal theme: background, foreground, ANSI palette, and cursor
        terminalView.terminalDelegate = coordinator
        terminalView.nativeBackgroundColor = TerminalTheme.backgroundColor
        terminalView.nativeForegroundColor = TerminalTheme.foregroundColor
        terminalView.installColors(TerminalTheme.ansiColors)
        terminalView.caretColor = TerminalTheme.cursorColor
        terminalView.caretTextColor = TerminalTheme.cursorTextColor

        // Add terminal view as subview
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateTerminalViewportInsets()

        // Pinch-to-zoom gesture for font size adjustment
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // Become first responder after a brief delay when keyboard should be visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isKeyboardVisible else { return }
            _ = self.terminalView.becomeFirstResponder()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTerminalViewportInsets()

        // Configure scrollback buffer once the Terminal object exists (created during first layout)
        if !scrollbackConfigured {
            let terminal = terminalView.getTerminal()
            terminal.options.scrollback = 10_000
            scrollbackConfigured = true
        }
    }

    func updateFontSize(_ size: CGFloat) {
        currentFontSize = size
        let font = Self.terminalFont(size: size)
        terminalView.font = font
    }

    func setKeyboardVisible(_ visible: Bool) {
        guard visible != isKeyboardVisible else { return }
        isKeyboardVisible = visible
        updateTerminalViewportInsets()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if visible {
                _ = self.terminalView.becomeFirstResponder()
            } else {
                _ = self.terminalView.resignFirstResponder()
            }
        }
    }

    private func updateTerminalViewportInsets() {
        let safeBottom = max(safeAreaInsets.bottom, terminalView.safeAreaInsets.bottom)
        let bottomInset = isKeyboardVisible ? (accessoryHeight + safeBottom) : 0
        if terminalView.contentInset.bottom != bottomInset {
            var inset = terminalView.contentInset
            inset.bottom = bottomInset
            terminalView.contentInset = inset
            terminalView.scrollIndicatorInsets = inset
            terminalView.repositionVisibleFrame()
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartFontSize = currentFontSize
        case .changed:
            // Scale font size proportionally, clamping to reasonable range
            let newSize = (pinchStartFontSize * gesture.scale).clamped(to: 8...32)
            currentFontSize = newSize
            let font = Self.terminalFont(size: newSize)
            terminalView.font = font
            coordinator?.fontSizeBinding.wrappedValue = newSize
        default:
            break
        }
    }
}

// Utility to clamp a comparable value to a range
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
