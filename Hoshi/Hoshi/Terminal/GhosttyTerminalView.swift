import SwiftUI
import UIKit
import GhosttyKit
import QuartzCore

struct GhosttyTerminalView: UIViewRepresentable {
    let connectionVM: ConnectionViewModel
    let appearanceSettings: AppearanceSettings
    @Binding var fontSize: CGFloat
    @Binding var showToolbarEditor: Bool
    @Binding var keyboardVisible: Bool
    var onSwapSession: (() -> Void)?
    var onSurfaceReady: ((GhosttyTerminalSurfaceView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            connectionVM: connectionVM,
            showToolbarEditorBinding: $showToolbarEditor,
            onSwapSession: onSwapSession
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
        view.onSwapSession = { [weak coordinator] in
            coordinator?.onSwapSession?()
        }

        connectionVM.setDataCallback { [weak view] bytes in
            DispatchQueue.main.async {
                view?.writeRemoteOutput(bytes)
            }
        }

        onSurfaceReady?(view)

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
        uiView.onSwapSession = { [weak coordinator] in
            coordinator?.onSwapSession?()
        }

        connectionVM.setDataCallback { [weak uiView] bytes in
            DispatchQueue.main.async {
                uiView?.writeRemoteOutput(bytes)
            }
        }

        uiView.updateFontSize(fontSize)
        uiView.setKeyboardVisible(keyboardVisible)
        uiView.applyAppearanceSettings(appearanceSettings)

        if !showToolbarEditor {
            uiView.reloadToolbarButtons()
        }
    }

    static func dismantleUIView(_ uiView: GhosttyTerminalSurfaceView, coordinator: Coordinator) {
        uiView.onInputData = nil
        uiView.onTerminalSizeChanged = nil
        uiView.onEditTap = nil
        uiView.onSwapSession = nil
        coordinator.connectionVM.setDataCallback(nil)
    }

    final class Coordinator {
        let connectionVM: ConnectionViewModel
        var showToolbarEditorBinding: Binding<Bool>?
        var onSwapSession: (() -> Void)?

        init(connectionVM: ConnectionViewModel, showToolbarEditorBinding: Binding<Bool>?, onSwapSession: (() -> Void)?) {
            self.connectionVM = connectionVM
            self.showToolbarEditorBinding = showToolbarEditorBinding
            self.onSwapSession = onSwapSession
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
    private var pendingPanScrollLines: CGFloat = 0
    private var snappedRenderSize: CGSize = .zero
    private weak var renderLayer: CALayer?
    private var recentDirectInputs: [(canonical: Data, time: CFTimeInterval)] = []
    private let mirroredInputWindow: CFTimeInterval = 0.08
    private let callbackDeferral: CFTimeInterval = 0.012
    // Track recent pressesBegan sends so insertText can suppress duplicates
    // when both paths fire for the same keystroke.
    private var lastPressSend: (data: Data, time: CFTimeInterval)?
    private let pressInsertOverlap: CFTimeInterval = 0.05
    private var lastAppliedSettingsHash: Int = 0
    private var pendingFocusRetryWorkItem: DispatchWorkItem?

    // Scrollbar indicator (added to superview so it composites above Metal)
    private let scrollbarOverlay: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.white.withAlphaComponent(0.4)
        view.layer.cornerRadius = 1.5
        view.alpha = 0
        view.isUserInteractionEnabled = false
        return view
    }()
    private var scrollbarFadeTimer: Timer?

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
    var onSwapSession: (() -> Void)?

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

        backgroundColor = AppearanceSettings.shared.currentTheme.background
        clipsToBounds = true

        toolbarAccessory.onButtonTap = { [weak self] bytes in
            self?.sendInputData(Data(bytes))
        }
        toolbarAccessory.onClipboardAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .copy:
                _ = self.copyToClipboard()
            case .paste:
                self.pasteFromClipboard()
            }
        }

        if let app {
            createSurface(app: app, fontSize: fontSize)
        }

        // Pinch to change font size
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // Single tap for mouse clicks (vim, htop, URLs)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // One-finger pan for scrolling the terminal buffer
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        // Long press + drag for mouse selection in terminal apps
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        addGestureRecognizer(longPress)

        // Pan should not fire while a long press is active
        pan.require(toFail: longPress)

        // Two-finger horizontal swipe to toggle to previous session
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerSwipe(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerPan)

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingFocusRetryWorkItem?.cancel()
        scrollbarFadeTimer?.invalidate()
        scrollbarOverlay.removeFromSuperview()
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
        // Use snapped (whole-cell) size when available so the Metal drawable
        // never extends beyond the grid. Fall back to full bounds before
        // cell metrics have been computed.
        let frame = snappedRenderSize != .zero
            ? CGRect(origin: .zero, size: snappedRenderSize)
            : CGRect(origin: .zero, size: layer.bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayer.frame = frame
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
        let data = Data(terminalText.utf8)

        // If pressesBegan already sent this exact data within the overlap
        // window, suppress the duplicate from insertText.
        if let last = lastPressSend,
           last.data == data,
           CACurrentMediaTime() - last.time <= pressInsertOverlap {
            lastPressSend = nil
            return
        }

        sendInputData(data)
    }

    func deleteBackward() {
        if Self.inputTraceEnabled {
            print("[INPUT_TRACE] deleteBackward")
        }
        sendInputData(Data([0x7f]))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        var unhandledPresses: Set<UIPress> = []

        for press in presses {
            guard let key = press.key else {
                // Soft-keyboard generated presses frequently carry no `UIKey`.
                // Forwarding those to `super` can trigger Ghostty's PTY callback
                // while `insertText` also fires, duplicating user input.
                handled = true
                continue
            }

            if key.modifierFlags.contains(.command) {
                let chars = key.charactersIgnoringModifiers.lowercased()
                if chars == "c" {
                    _ = copyToClipboard()
                    handled = true
                } else if chars == "v" {
                    pasteFromClipboard()
                    handled = true
                } else {
                    unhandledPresses.insert(press)
                }
                continue
            }

            if shouldHandlePressDirectly(key) {
                guard let data = dataForKey(key) else { continue }
                sendInputData(data)
                handled = true
            } else {
                // Send printable keys directly — insertText may not fire for
                // hardware keyboards when super.pressesBegan is not called.
                // The insertText dedup guard prevents doubles when both paths fire.
                let chars = key.characters
                if !chars.isEmpty {
                    let terminalChars = chars.replacingOccurrences(of: "\n", with: "\r")
                    let data = Data(terminalChars.utf8)
                    lastPressSend = (data, CACurrentMediaTime())
                    sendInputData(data)
                }
                handled = true
            }
        }

        if !unhandledPresses.isEmpty {
            super.pressesBegan(unhandledPresses, with: event)
        } else if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Render layer frame is set by updateSurfaceSizeIfNeeded to the
        // snapped (whole-cell) size. Only fall back to full bounds before
        // the surface exists and cell metrics are available.
        if surface == nil, let renderLayer, renderLayer.superlayer === layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderLayer.frame = layer.bounds
            CATransaction.commit()
        }
        updateSurfaceSizeIfNeeded()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        // Add scrollbar as a sibling so it composites above the Metal layer
        if let superview {
            scrollbarOverlay.removeFromSuperview()
            superview.addSubview(scrollbarOverlay)
        } else {
            scrollbarOverlay.removeFromSuperview()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let surface else { return }

        ghostty_surface_set_occlusion(surface, window != nil)
        if window != nil {
            updateSurfaceSizeIfNeeded()
            scheduleFocusAcquisition()
        } else {
            pendingFocusRetryWorkItem?.cancel()
            pendingFocusRetryWorkItem = nil
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
        guard visible != isKeyboardVisible else {
            // SwiftUI often presents the terminal with `keyboardVisible == true`
            // from the start. In that case we still need an explicit first-
            // responder request, otherwise the terminal stays inert until the
            // user toggles keyboard visibility later.
            if visible {
                scheduleFocusAcquisition()
            }
            return
        }
        isKeyboardVisible = visible

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if visible {
                self.scheduleFocusAcquisition()
            } else {
                self.pendingFocusRetryWorkItem?.cancel()
                self.pendingFocusRetryWorkItem = nil
                _ = self.resignFirstResponder()
                self.updateSurfaceFocus()
            }
        }
    }

    func reloadToolbarButtons() {
        toolbarAccessory.reloadButtons()
    }

    // Apply appearance settings to the live surface, skipping if nothing changed
    func applyAppearanceSettings(_ settings: AppearanceSettings) {
        let hash = settings.settingsHash
        guard hash != lastAppliedSettingsHash else { return }
        lastAppliedSettingsHash = hash

        guard let surface else { return }

        // Build a new config and push it to the surface
        if let cfg = GhosttyRuntimeController.shared.buildConfig(for: settings) {
            ghostty_surface_update_config(surface, cfg)
            ghostty_config_free(cfg)
        }

        // Apply color scheme
        let scheme: ghostty_color_scheme_e = switch settings.colorScheme {
        case .dark: GHOSTTY_COLOR_SCHEME_DARK
        case .light: GHOSTTY_COLOR_SCHEME_LIGHT
        case .system: GHOSTTY_COLOR_SCHEME_DARK
        }
        ghostty_surface_set_color_scheme(surface, scheme)

        // Update background color to match theme
        backgroundColor = settings.currentTheme.background
    }

    // Snapshot the terminal for thumbnail use, downscaled to ~400pt wide
    func captureSnapshot() -> UIImage? {
        guard let renderLayer, renderLayer.bounds.width > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let fullImage = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }
        let scale = min(1.0, 400.0 / bounds.width)
        let targetSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return fullImage.preparingThumbnail(of: targetSize)
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

    func hasSelection() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    func readSelection() -> String? {
        guard let surface else { return nil }

        var selectedText = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selectedText) else { return nil }
        defer { ghostty_surface_free_text(surface, &selectedText) }

        let text = String(cString: selectedText.text)
        return text.isEmpty ? nil : text
    }

    @discardableResult
    func copyToClipboard() -> Bool {
        guard let selectedText = readSelection() else { return false }
        UIPasteboard.general.string = selectedText
        return true
    }

    func pasteFromClipboard() {
        guard let surface, UIPasteboard.general.hasStrings else { return }
        let action = "paste_from_clipboard"
        action.withCString { cAction in
            _ = ghostty_surface_binding_action(surface, cAction, UInt(action.utf8.count))
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

    static func updateScrollbar(for surface: ghostty_surface_t, total: UInt64, offset: UInt64, len: UInt64) {
        let ptr = UnsafeRawPointer(surface)

        registryLock.lock()
        let view = surfaceRegistry[ptr]?.view
        registryLock.unlock()

        guard let view else { return }
        DispatchQueue.main.async {
            view.updateScrollbarIndicator(total: total, offset: offset, len: len)
        }
    }

    // Position and show the scrollbar thumb based on Ghostty's scrollback state
    private func updateScrollbarIndicator(total: UInt64, offset: UInt64, len: UInt64) {
        // All content fits on screen — hide the scrollbar
        guard total > len else {
            hideScrollbar()
            return
        }

        let trackInset: CGFloat = 4
        let scrollbarWidth: CGFloat = 3
        let trackHeight = frame.height - trackInset * 2

        let thumbHeight = max(20, CGFloat(len) / CGFloat(total) * trackHeight)
        let thumbY = trackInset + CGFloat(offset) / CGFloat(total) * trackHeight

        // Position in superview coordinates
        scrollbarOverlay.frame = CGRect(
            x: frame.maxX - scrollbarWidth - 2,
            y: frame.minY + thumbY,
            width: scrollbarWidth,
            height: thumbHeight
        )

        // Fade in
        if scrollbarOverlay.alpha < 1 {
            UIView.animate(withDuration: 0.15) {
                self.scrollbarOverlay.alpha = 1
            }
        }

        // Reset the fade-out timer
        scrollbarFadeTimer?.invalidate()
        scrollbarFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hideScrollbar()
            }
        }
    }

    private func hideScrollbar() {
        scrollbarFadeTimer?.invalidate()
        scrollbarFadeTimer = nil
        UIView.animate(withDuration: 0.3) {
            self.scrollbarOverlay.alpha = 0
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

        let scheme: ghostty_color_scheme_e = switch AppearanceSettings.shared.colorScheme {
        case .dark: GHOSTTY_COLOR_SCHEME_DARK
        case .light: GHOSTTY_COLOR_SCHEME_LIGHT
        case .system: GHOSTTY_COLOR_SCHEME_DARK
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        ghostty_surface_set_occlusion(surface, true)
        updateSurfaceFocus()

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

        // Pass full pixel dimensions so Ghostty can compute cell metrics
        let widthPx = max(1, Int((bounds.width * scale).rounded(.down)))
        let heightPx = max(1, Int((bounds.height * scale).rounded(.down)))
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(widthPx), UInt32(heightPx))

        let grid = ghostty_surface_size(surface)

        // Snap the framebuffer to exact cell multiples so the Metal drawable
        // never contains a partial row or column at the edges.
        if grid.cell_width_px > 0, grid.cell_height_px > 0 {
            let cellW = Int(grid.cell_width_px)
            let cellH = Int(grid.cell_height_px)
            let cols = max(1, widthPx / cellW)
            let rows = max(1, heightPx / cellH)
            let snappedW = UInt32(cols * cellW)
            let snappedH = UInt32(rows * cellH)

            // Re-set only when the snapped size differs from raw
            if snappedW != UInt32(widthPx) || snappedH != UInt32(heightPx) {
                ghostty_surface_set_size(surface, snappedW, snappedH)
            }

            // Size the render layer to the snapped dimensions (in points)
            let snapped = CGSize(
                width: CGFloat(snappedW) / scale,
                height: CGFloat(snappedH) / scale
            )
            snappedRenderSize = snapped

            if let renderLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                renderLayer.frame = CGRect(origin: .zero, size: snapped)
                CATransaction.commit()
            }
        }

        let finalGrid = ghostty_surface_size(surface)
        let finalCols = Int(finalGrid.columns)
        let finalRows = Int(finalGrid.rows)

        if forceResizeSignal || finalCols != lastGridSize.cols || finalRows != lastGridSize.rows {
            lastGridSize = (finalCols, finalRows)
            onTerminalSizeChanged?(finalCols, finalRows)
        }
    }

    private func updateSurfaceFocus() {
        guard let surface else { return }

        // Keyboard visibility and terminal focus are not the same thing.
        // On iPad, dismissing the software keyboard should not stop tmux or
        // shell output from repainting the visible terminal surface.
        let shouldFocusSurface = window != nil
        ghostty_surface_set_focus(surface, shouldFocusSurface)
    }

    private func scheduleFocusAcquisition(attempt: Int = 0) {
        guard isKeyboardVisible else { return }

        pendingFocusRetryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.window != nil else { return }

            if !self.isFirstResponder {
                _ = self.becomeFirstResponder()
            }
            self.updateSurfaceFocus()

            if !self.isFirstResponder, attempt < 10 {
                self.scheduleFocusAcquisition(attempt: attempt + 1)
            }
        }

        pendingFocusRetryWorkItem = workItem

        let delay = attempt == 0 ? 0.35 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func sendInputData(_ data: Data) {
        guard !data.isEmpty else { return }

        // Snap viewport to bottom on any user keystroke
        if let surface {
            let action = "scroll_to_bottom"
            action.withCString { cAction in
                _ = ghostty_surface_binding_action(surface, cAction, UInt(action.utf8.count))
            }
        }

        let transformed = toolbarAccessory.applyModifiersIfNeeded(to: ArraySlice(data))
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
                if !hasMirroredDirect {
                    self.onInputData?(data)
                }
            }
        }
    }

    private func handlePtyInputCallback(_ data: Data) {
        guard !data.isEmpty else { return }
        forwardInputData(data, source: .ptyCallback)
    }

    // Collapse newlines for dedup comparison: CRLF → CR, lone LF → CR.
    // The old byte-swap turned \r\n into \r\r, which never matched a
    // direct \r and let double-enters slip through.
    private func canonicalInputForDedup(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var prev: UInt8? = nil
        for b in data {
            if b == 0x0A {
                if prev == 0x0D {
                    // CRLF → CR (drop the LF, CR already emitted)
                    prev = 0x0D
                    continue
                }
                // Lone LF → CR
                out.append(0x0D)
                prev = 0x0D
            } else {
                out.append(b)
                prev = b
            }
        }
        return out
    }

    private static func hexBytes(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
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

    // MARK: - Gesture → Ghostty Mouse/Scroll Events

    // Tap sends a click at the tap location for mouse-aware apps (vim, htop, URLs)
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let surface else { return }
        let pos = gesture.location(in: self)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    // Pan scrolls the terminal buffer using natural scrolling (swipe down = see history)
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        switch gesture.state {
        case .began:
            pendingPanScrollLines = 0

        case .changed:
            let delta = gesture.translation(in: self)
            let multiplier = AppearanceSettings.shared.scrollMultiplier

            if ghostty_surface_mouse_captured(surface) {
                // Preserve app-directed wheel behavior only when the terminal
                // explicitly requested mouse capture.
                ghostty_surface_mouse_scroll(surface, 0, delta.y * multiplier, 1)
                gesture.setTranslation(.zero, in: self)
                return
            }

            let size = ghostty_surface_size(surface)
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let cellHeight = CGFloat(size.cell_height_px) / max(scale, 1)
            guard cellHeight > 0 else {
                gesture.setTranslation(.zero, in: self)
                return
            }

            // Touch pan should scroll the viewport, not synthesize cursor keys
            // in alternate-screen apps that don't capture the mouse.
            pendingPanScrollLines += (delta.y * multiplier) / cellHeight

            let lineDelta = Int(pendingPanScrollLines.rounded(.towardZero))
            if lineDelta != 0 {
                let action = "scroll_page_lines:\(-lineDelta)"
                action.withCString { cAction in
                    _ = ghostty_surface_binding_action(surface, cAction, UInt(action.utf8.count))
                }
                pendingPanScrollLines -= CGFloat(lineDelta)
            }

            gesture.setTranslation(.zero, in: self)

        case .ended, .cancelled, .failed:
            pendingPanScrollLines = 0

        default:
            break
        }
    }

    // Long press + drag for mouse selection in terminal apps
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let surface else { return }
        let pos = gesture.location(in: self)

        switch gesture.state {
        case .began:
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        case .changed:
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
        case .ended:
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            if copyToClipboard() {
                HapticService.lightTap()
            }
        case .cancelled:
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        default:
            break
        }
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

    // Two-finger horizontal swipe triggers session swap (fires once per gesture)
    @objc private func handleTwoFingerSwipe(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let velocity = gesture.velocity(in: self)
        // Require meaningful horizontal velocity to avoid accidental triggers
        guard abs(velocity.x) > 500, abs(velocity.x) > abs(velocity.y) else { return }
        onSwapSession?()
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
