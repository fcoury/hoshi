import SwiftUI
import UIKit
import GhosttyKit
import QuartzCore

struct GhosttyTerminalView: UIViewRepresentable {
    let connectionVM: ConnectionViewModel
    @Binding var fontSize: CGFloat
    @Binding var showToolbarEditor: Bool
    @Binding var keyboardVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            connectionVM: connectionVM,
            showToolbarEditorBinding: $showToolbarEditor
        )
    }

    func makeUIView(context: Context) -> GhosttyTerminalSurfaceView {
        let runtime = GhosttyRuntimeController.shared
        let view = GhosttyTerminalSurfaceView(
            app: runtime.app,
            fontSize: fontSize,
            keyboardVisible: keyboardVisible
        )

        let coordinator = context.coordinator
        view.onInputData = { [weak coordinator] data in
            coordinator?.sendInput(data)
        }
        view.onTerminalSizeChanged = { [weak coordinator] cols, rows in
            coordinator?.updateSize(cols: cols, rows: rows)
        }
        view.onEditTap = { [weak coordinator] in
            coordinator?.showToolbarEditorBinding?.wrappedValue = true
        }

        connectionVM.setDataCallback { [weak view] bytes in
            DispatchQueue.main.async {
                view?.writeRemoteOutput(bytes)
            }
        }

        return view
    }

    func updateUIView(_ uiView: GhosttyTerminalSurfaceView, context: Context) {
        let coordinator = context.coordinator
        uiView.onInputData = { [weak coordinator] data in
            coordinator?.sendInput(data)
        }
        uiView.onTerminalSizeChanged = { [weak coordinator] cols, rows in
            coordinator?.updateSize(cols: cols, rows: rows)
        }
        uiView.onEditTap = { [weak coordinator] in
            coordinator?.showToolbarEditorBinding?.wrappedValue = true
        }

        connectionVM.setDataCallback { [weak uiView] bytes in
            DispatchQueue.main.async {
                uiView?.writeRemoteOutput(bytes)
            }
        }

        uiView.updateFontSize(fontSize)
        uiView.setKeyboardVisible(keyboardVisible)

        if !showToolbarEditor {
            uiView.reloadToolbarButtons()
        }
    }

    static func dismantleUIView(_ uiView: GhosttyTerminalSurfaceView, coordinator: Coordinator) {
        uiView.onInputData = nil
        uiView.onTerminalSizeChanged = nil
        uiView.onEditTap = nil
        coordinator.connectionVM.setDataCallback(nil)
    }

    final class Coordinator {
        let connectionVM: ConnectionViewModel
        var showToolbarEditorBinding: Binding<Bool>?

        init(connectionVM: ConnectionViewModel, showToolbarEditorBinding: Binding<Bool>?) {
            self.connectionVM = connectionVM
            self.showToolbarEditorBinding = showToolbarEditorBinding
        }

        func sendInput(_ data: Data) {
            Task { @MainActor in
                await connectionVM.send(data)
            }
        }

        func updateSize(cols: Int, rows: Int) {
            Task { @MainActor in
                await connectionVM.resize(cols: cols, rows: rows)
            }
        }
    }
}

final class GhosttyTerminalSurfaceView: UIView, UIKeyInput, UITextInputTraits {
    private static let inputTraceEnabled = ProcessInfo.processInfo.environment["HOSHI_INPUT_TRACE"] == "1"

    private enum InputSource {
        case direct
        case ptyCallback
    }

    private final class WeakViewRef {
        weak var view: GhosttyTerminalSurfaceView?

        init(_ view: GhosttyTerminalSurfaceView) {
            self.view = view
        }
    }

    private static var surfaceRegistry: [UnsafeRawPointer: WeakViewRef] = [:]
    private static let registryLock = NSLock()

    private let app: ghostty_app_t?
    private(set) var surface: ghostty_surface_t?

    private var currentFontSize: CGFloat
    private var pinchStartFontSize: CGFloat = 14
    private var isKeyboardVisible: Bool
    private var lastGridSize: (cols: Int, rows: Int) = (0, 0)
    private weak var renderLayer: CALayer?
    private var recentDirectInputs: [(canonical: Data, time: CFTimeInterval)] = []
    private let mirroredInputWindow: CFTimeInterval = 0.08
    private let callbackDeferral: CFTimeInterval = 0.012

    let toolbarAccessory: KeyboardToolbarAccessoryView

    var onInputData: ((Data) -> Void)?
    var onTerminalSizeChanged: ((Int, Int) -> Void)? {
        didSet {
            guard onTerminalSizeChanged != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.updateSurfaceSizeIfNeeded(forceResizeSignal: true)
            }
        }
    }
    var onTitleChanged: ((String) -> Void)?
    var onEditTap: (() -> Void)? {
        didSet {
            toolbarAccessory.onEditTap = onEditTap
        }
    }

    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    init(app: ghostty_app_t?, fontSize: CGFloat, keyboardVisible: Bool) {
        self.app = app
        self.currentFontSize = fontSize
        self.isKeyboardVisible = keyboardVisible
        self.toolbarAccessory = KeyboardToolbarAccessoryView()

        super.init(frame: .zero)

        backgroundColor = TerminalTheme.backgroundColor
        clipsToBounds = true

        toolbarAccessory.onButtonTap = { [weak self] bytes in
            self?.sendInputData(Data(bytes))
        }

        if let app {
            createSurface(app: app, fontSize: fontSize)
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        if keyboardVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                _ = self.becomeFirstResponder()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let surface {
            Self.unregister(surface: surface)
            ghostty_surface_free(surface)
        }
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var inputAccessoryView: UIView? {
        toolbarAccessory
    }

    // Ghostty's current iOS Metal path sends addSublayer: to the provided UIView.
    // Forward it to our backing CALayer to avoid unrecognized selector crashes.
    @objc(addSublayer:)
    func addSublayerCompat(_ sublayer: CALayer) {
        // Keep Ghostty's render layer matched to our view bounds.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayer.frame = layer.bounds
        CATransaction.commit()
        layer.addSublayer(sublayer)
        renderLayer = sublayer
        setNeedsLayout()
    }

    var hasText: Bool {
        true
    }

    func insertText(_ text: String) {
        let terminalText = text.replacingOccurrences(of: "\n", with: "\r")
        if Self.inputTraceEnabled {
            print("[INPUT_TRACE] insertText text=\(String(reflecting: text)) terminal=\(String(reflecting: terminalText))")
        }
        sendInputData(Data(terminalText.utf8))
    }

    func deleteBackward() {
        if Self.inputTraceEnabled {
            print("[INPUT_TRACE] deleteBackward")
        }
        sendInputData(Data([0x7f]))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else {
                // Soft-keyboard generated presses frequently carry no `UIKey`.
                // Forwarding those to `super` can trigger Ghostty's PTY callback
                // while `insertText` also fires, duplicating user input.
                handled = true
                continue
            }

            if shouldHandlePressDirectly(key) {
                guard let data = dataForKey(key) else { continue }
                if Self.inputTraceEnabled {
                    print("[INPUT_TRACE] pressesBegan direct keyCode=\(key.keyCode.rawValue) chars=\(String(reflecting: key.characters)) bytes=\(Self.hexBytes(data))")
                }
                sendInputData(data)
                handled = true
            } else {
                // Printable keys should be delivered by UITextInput (`insertText`).
                // Forwarding these presses to `super` can trigger an additional
                // Ghostty PTY callback path and duplicate the input.
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let renderLayer, renderLayer.superlayer === layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderLayer.frame = layer.bounds
            CATransaction.commit()
        }
        updateSurfaceSizeIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let surface else { return }

        ghostty_surface_set_occlusion(surface, window != nil)
        if window != nil {
            updateSurfaceSizeIfNeeded()
        }
    }

    func writeRemoteOutput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.writeRemoteOutput(bytes)
            }
            return
        }

        guard let surface else { return }
        let data = Data(bytes)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            base.assumingMemoryBound(to: CChar.self).withMemoryRebound(to: CChar.self, capacity: data.count) { charPtr in
                ghostty_surface_write_pty_output(surface, charPtr, UInt(data.count))
            }
        }
        ghostty_surface_refresh(surface)
    }

    func setKeyboardVisible(_ visible: Bool) {
        guard visible != isKeyboardVisible else { return }
        isKeyboardVisible = visible

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if visible {
                _ = self.becomeFirstResponder()
                if let surface = self.surface {
                    ghostty_surface_set_focus(surface, true)
                }
            } else {
                _ = self.resignFirstResponder()
                if let surface = self.surface {
                    ghostty_surface_set_focus(surface, false)
                }
            }
        }
    }

    func reloadToolbarButtons() {
        toolbarAccessory.reloadButtons()
    }

    func updateFontSize(_ size: CGFloat) {
        guard abs(size - currentFontSize) >= 0.25 else { return }
        guard let surface else {
            currentFontSize = size
            return
        }

        let direction = size > currentFontSize ? "increase_font_size:1" : "decrease_font_size:1"
        let steps = max(1, Int((abs(size - currentFontSize) / 0.5).rounded()))

        for _ in 0..<steps {
            direction.withCString { cAction in
                _ = ghostty_surface_binding_action(surface, cAction, UInt(direction.utf8.count))
            }
        }

        currentFontSize = size
        updateSurfaceSizeIfNeeded(forceResizeSignal: true)
    }

    func completeClipboardRequest(state: UnsafeMutableRawPointer, content: String, confirmed: Bool) {
        guard let surface else { return }
        content.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, state, confirmed)
        }
    }

    static func updateTitle(for surface: ghostty_surface_t, title: String) {
        let ptr = UnsafeRawPointer(surface)

        registryLock.lock()
        let view = surfaceRegistry[ptr]?.view
        registryLock.unlock()

        guard let view else { return }
        DispatchQueue.main.async {
            view.onTitleChanged?(title)
        }
    }

    static func requestRender(for surface: ghostty_surface_t) {
        let ptr = UnsafeRawPointer(surface)

        registryLock.lock()
        let view = surfaceRegistry[ptr]?.view
        registryLock.unlock()

        guard let view else { return }
        DispatchQueue.main.async {
            view.renderLayer?.setNeedsDisplay()
            view.layer.setNeedsDisplay()
            view.setNeedsDisplay()
            view.setNeedsLayout()
        }
    }

    private func createSurface(app: ghostty_app_t, fontSize: CGFloat) {
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = UIScreen.main.scale
        config.font_size = Float(fontSize)

        guard let surface = ghostty_surface_new(app, &config) else {
            return
        }

        self.surface = surface
        Self.register(surface: surface, view: self)

        ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_DARK)
        ghostty_surface_set_focus(surface, isKeyboardVisible)
        ghostty_surface_set_occlusion(surface, true)

        ghostty_surface_set_pty_input_callback(surface) { userdata, data, len in
            guard let userdata, let data, len > 0 else { return }
            let view = Unmanaged<GhosttyTerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let input = Data(bytes: data, count: Int(len))
            DispatchQueue.main.async {
                view.handlePtyInputCallback(input)
            }
        }
    }

    private func updateSurfaceSizeIfNeeded(forceResizeSignal: Bool = false) {
        guard let surface else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = max(1, window?.screen.scale ?? UIScreen.main.scale)
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }
        if layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        if let renderLayer, renderLayer.contentsScale != scale {
            renderLayer.contentsScale = scale
        }
        // Never round up framebuffer pixels: requesting a larger surface than the
        // visible view can clip the last row on 3x devices.
        let widthPx = max(1, Int((bounds.width * scale).rounded(.down)))
        let heightPx = max(1, Int((bounds.height * scale).rounded(.down)))
        var width = UInt32(widthPx)
        var height = UInt32(heightPx)

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, width, height)

        var grid = ghostty_surface_size(surface)

        // Defensive correction: if Ghostty reports a grid that would overflow
        // the current framebuffer, resize to a whole-cell framebuffer that fits.
        if grid.cell_width_px > 0, grid.cell_height_px > 0 {
            let cellWidth = Int(grid.cell_width_px)
            let cellHeight = Int(grid.cell_height_px)
            let gridWidth = Int(grid.columns) * cellWidth
            let gridHeight = Int(grid.rows) * cellHeight

            if gridWidth > widthPx || gridHeight > heightPx {
                let safeCols = max(1, min(Int(grid.columns), widthPx / cellWidth))
                let safeRows = max(1, min(Int(grid.rows), heightPx / cellHeight))
                width = UInt32(max(cellWidth, safeCols * cellWidth))
                height = UInt32(max(cellHeight, safeRows * cellHeight))
                ghostty_surface_set_size(surface, width, height)
                grid = ghostty_surface_size(surface)
            }
        }

        let cols = Int(grid.columns)
        let rows = Int(grid.rows)

        if forceResizeSignal || cols != lastGridSize.cols || rows != lastGridSize.rows {
            lastGridSize = (cols, rows)
            onTerminalSizeChanged?(cols, rows)
        }
    }

    private func sendInputData(_ data: Data) {
        guard !data.isEmpty else { return }

        let transformed = toolbarAccessory.applyCtrlModifierIfNeeded(to: ArraySlice(data))
        if Self.inputTraceEnabled {
            print("[INPUT_TRACE] sendInputData direct bytes=\(Self.hexBytes(Data(transformed)))")
        }
        forwardInputData(Data(transformed), source: .direct)
    }

    private func forwardInputData(_ data: Data, source: InputSource) {
        guard !data.isEmpty else { return }

        let now = CACurrentMediaTime()
        let canonical = canonicalInputForDedup(data)
        recentDirectInputs.removeAll { now - $0.time > mirroredInputWindow }

        switch source {
        case .direct:
            recentDirectInputs.append((canonical, now))
            if Self.inputTraceEnabled {
                print("[INPUT_TRACE] forward direct bytes=\(Self.hexBytes(data)) canonical=\(Self.hexBytes(canonical))")
            }
            onInputData?(data)
        case .ptyCallback:
            // The callback can race with UITextInput events and arrive first.
            // Defer briefly so mirrored direct input can land, then suppress
            // only closely-time-matched equivalent callbacks.
            DispatchQueue.main.asyncAfter(deadline: .now() + callbackDeferral) { [weak self] in
                guard let self else { return }
                let checkTime = CACurrentMediaTime()
                self.recentDirectInputs.removeAll { checkTime - $0.time > self.mirroredInputWindow }
                let hasMirroredDirect = self.recentDirectInputs.contains {
                    $0.canonical == canonical && abs($0.time - now) <= self.mirroredInputWindow
                }
                if Self.inputTraceEnabled {
                    print("[INPUT_TRACE] forward pty bytes=\(Self.hexBytes(data)) canonical=\(Self.hexBytes(canonical)) mirrored=\(hasMirroredDirect)")
                }
                if !hasMirroredDirect {
                    self.onInputData?(data)
                }
            }
        }
    }

    private func handlePtyInputCallback(_ data: Data) {
        guard !data.isEmpty else { return }
        if Self.inputTraceEnabled {
            print("[INPUT_TRACE] ptyCallback bytes=\(Self.hexBytes(data))")
        }
        // Preserve PTY callback-originated input paths while letting the
        // dedup logic in `forwardInputData` suppress mirrored key events.
        forwardInputData(data, source: .ptyCallback)
    }

    private static func hexBytes(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func canonicalInputForDedup(_ data: Data) -> Data {
        var canonical = data
        canonical.withUnsafeMutableBytes { buffer in
            for idx in 0..<buffer.count {
                if buffer[idx] == 0x0a {
                    buffer[idx] = 0x0d
                }
            }
        }
        return canonical
    }

    private func shouldHandlePressDirectly(_ key: UIKey) -> Bool {
        if key.modifierFlags.contains(.control) || key.modifierFlags.contains(.alternate) {
            return true
        }

        switch key.keyCode {
        case .keyboardEscape,
             .keyboardUpArrow,
             .keyboardDownArrow,
             .keyboardRightArrow,
             .keyboardLeftArrow,
             .keyboardDeleteForward,
             .keyboardHome,
             .keyboardEnd,
             .keyboardPageUp,
             .keyboardPageDown:
            return true
        default:
            // Printable keys, Return, Tab, and Backspace should flow through the
            // text input path (`insertText`/`deleteBackward`) to avoid duplicates.
            return false
        }
    }

    private func dataForKey(_ key: UIKey) -> Data? {
        switch key.keyCode {
        case .keyboardEscape:
            return Data([0x1b])
        case .keyboardUpArrow:
            return Data([0x1b, 0x5b, 0x41])
        case .keyboardDownArrow:
            return Data([0x1b, 0x5b, 0x42])
        case .keyboardRightArrow:
            return Data([0x1b, 0x5b, 0x43])
        case .keyboardLeftArrow:
            return Data([0x1b, 0x5b, 0x44])
        case .keyboardTab:
            return Data([0x09])
        case .keyboardReturnOrEnter:
            return Data([0x0d])
        case .keyboardDeleteOrBackspace:
            return Data([0x7f])
        case .keyboardDeleteForward:
            return Data([0x1b, 0x5b, 0x33, 0x7e])
        case .keyboardHome:
            return Data([0x1b, 0x5b, 0x48])
        case .keyboardEnd:
            return Data([0x1b, 0x5b, 0x46])
        case .keyboardPageUp:
            return Data([0x1b, 0x5b, 0x35, 0x7e])
        case .keyboardPageDown:
            return Data([0x1b, 0x5b, 0x36, 0x7e])
        default:
            break
        }

        guard !key.charactersIgnoringModifiers.isEmpty else {
            return nil
        }

        let characters = key.charactersIgnoringModifiers.lowercased()

        if key.modifierFlags.contains(.control),
           let value = characters.utf8.first,
           value >= 97,
           value <= 122 {
            return Data([value - 96])
        }

        guard var data = characters.data(using: .utf8) else {
            return nil
        }

        if key.modifierFlags.contains(.alternate) {
            data.insert(0x1b, at: 0)
        }

        return data
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartFontSize = currentFontSize

        case .changed:
            let size = (pinchStartFontSize * gesture.scale).clamped(to: 8...32)
            updateFontSize(size)

        default:
            break
        }
    }

    private static func register(surface: ghostty_surface_t, view: GhosttyTerminalSurfaceView) {
        let ptr = UnsafeRawPointer(surface)
        registryLock.lock()
        surfaceRegistry[ptr] = WeakViewRef(view)
        registryLock.unlock()
    }

    private static func unregister(surface: ghostty_surface_t) {
        let ptr = UnsafeRawPointer(surface)
        registryLock.lock()
        surfaceRegistry.removeValue(forKey: ptr)
        registryLock.unlock()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
