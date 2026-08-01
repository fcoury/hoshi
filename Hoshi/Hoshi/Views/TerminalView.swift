import SwiftUI

/// Full-screen terminal emulator view wrapping a Ghostty Metal surface.
///
/// Owns the status bar, connection banners, keyboard toolbar lifecycle,
/// and pinch-to-zoom font sizing. Delegates actual terminal rendering
/// to `GhosttyTerminalView`.
///
/// Connection state drives three visual behaviors:
/// - **Status dot** pulses during transient states (connecting, reconnecting).
/// - **Banners** slide in as floating pills for reconnecting/disconnected states.
/// - **Haptic feedback** fires on every state transition (success, warning, error).
///
/// The view auto-dismisses when the connection drops from a previously-connected
/// state (e.g. user typed `exit`), returning the user to the server list.
struct TerminalView: View {
    @Bindable var connectionVM: ConnectionViewModel
    var managedSession: ManagedSession?
    var canSwapSession: Bool = false
    var onSwapSession: (() -> Void)?
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appearanceSettings = AppearanceSettings.shared

    // Font size state for pinch-to-zoom (initialized from settings)
    @State private var fontSize: CGFloat = AppearanceSettings.shared.fontSize

    // Toolbar edit sheet
    @State private var showToolbarEditor = false
    @State private var showTmuxPalette = false

    // Keyboard visibility for explicit show/hide control
    @State private var isKeyboardVisible = true
    @State private var keyboardVisibleBeforeToolbarEditor = true
    @State private var keyboardVisibleBeforeTmuxPalette = true

    // Unsafe pastes and remote clipboard requests require explicit approval.
    @State private var pendingClipboardRequest: TerminalClipboardRequest?
    @State private var keyboardVisibleBeforeClipboardPrompt = false

    // Status dot pulse animation for connecting/reconnecting states
    @State private var statusDotPulsing = false

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

            // Connection status banners — slide in from top
            if connectionVM.connectionState == .reconnecting {
                reconnectingBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if connectionVM.connectionState == .disconnected && connectionVM.hasActiveSession {
                disconnectedBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            GhosttyTerminalView(
                connectionVM: connectionVM,
                managedSession: managedSession,
                appearanceSettings: appearanceSettings,
                fontSize: $fontSize,
                showToolbarEditor: $showToolbarEditor,
                keyboardVisible: $isKeyboardVisible,
                onClipboardRequest: { request in
                    keyboardVisibleBeforeClipboardPrompt = isKeyboardVisible
                    pendingClipboardRequest = request
                },
                onSwapSession: canSwapSession ? onSwapSession : nil,
                onSurfaceReady: { surfaceView in
                    // Capture weak reference to the surface for thumbnail snapshots
                    managedSession?.surfaceView = surfaceView
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: connectionVM.connectionState)
        .onChange(of: fontSize) { _, newSize in
            appearanceSettings.fontSize = newSize
        }
        .onChange(of: connectionVM.connectionState) { oldState, newState in
            // Haptic feedback for connection state transitions
            switch newState {
            case .connected:
                HapticService.success()
            case .reconnecting:
                HapticService.warning()
            case .disconnected where oldState == .connected:
                HapticService.error()
            case .error:
                HapticService.error()
            default:
                break
            }

            // Auto-dismiss when session ends naturally (user typed 'exit')
            if oldState == .connected {
                if newState == .disconnected {
                    onDismiss?()
                } else if case .error = newState {
                    onDismiss?()
                }
            }
        }
        .onChange(of: showToolbarEditor) { _, isPresented in
            if isPresented {
                keyboardVisibleBeforeToolbarEditor = isKeyboardVisible
            } else if keyboardVisibleBeforeToolbarEditor {
                isKeyboardVisible = true
            }
        }
        .onChange(of: showTmuxPalette) { _, isPresented in
            if isPresented {
                keyboardVisibleBeforeTmuxPalette = isKeyboardVisible
            } else if keyboardVisibleBeforeTmuxPalette {
                isKeyboardVisible = true
            }
        }
        .sheet(isPresented: $showToolbarEditor) {
            ToolbarEditView(onSave: {
                // GhosttyTerminalView reloads toolbar buttons after dismissal.
            })
        }
        .sheet(isPresented: $showTmuxPalette) {
            TmuxCommandPaletteView { bytes in
                Task { await connectionVM.sendBytes(ArraySlice(bytes)) }
            }
        }
        .alert(
            pendingClipboardRequest?.kind.title ?? "Confirm Paste",
            isPresented: Binding(
                get: { pendingClipboardRequest != nil },
                set: { isPresented in
                    guard !isPresented, let request = pendingClipboardRequest else { return }
                    resolveClipboardRequest(request, approved: false)
                }
            ),
            presenting: pendingClipboardRequest
        ) { request in
            Button("Cancel", role: .cancel) {
                resolveClipboardRequest(request, approved: false)
            }
            Button(request.kind.confirmButtonTitle) {
                resolveClipboardRequest(request, approved: true)
            }
        } message: { request in
            Text(request.message)
        }
        .overlay {
            if scenePhase != .active {
                privacyCover
            }
        }
    }

    private var privacyCover: some View {
        ZStack {
            SwiftUI.Color(appearanceSettings.currentTheme.background)
            Image(systemName: "lock.shield")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityLabel("Terminal contents hidden")
    }

    private func resolveClipboardRequest(_ request: TerminalClipboardRequest, approved: Bool) {
        guard pendingClipboardRequest?.id == request.id else { return }
        let shouldRestoreKeyboard = keyboardVisibleBeforeClipboardPrompt
        pendingClipboardRequest = nil
        request.onDecision(approved)

        guard shouldRestoreKeyboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pendingClipboardRequest == nil else { return }
            isKeyboardVisible = true
        }
    }

    // Whether the status dot should pulse (connecting/reconnecting states)
    private var isTransientState: Bool {
        switch connectionVM.connectionState {
        case .connecting, .sshBootstrap, .moshStarting, .reconnecting:
            return true
        default:
            return false
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Connection status indicator — pulses during transient states
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .scaleEffect(statusDotPulsing ? 1.3 : 1.0)
                .opacity(statusDotPulsing ? 0.7 : 1.0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: statusColor)
                .onChange(of: isTransientState) { _, pulsing in
                    if pulsing && !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            statusDotPulsing = true
                        }
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            statusDotPulsing = false
                        }
                    }
                }
                .onAppear {
                    if isTransientState && !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            statusDotPulsing = true
                        }
                    }
                }
                .accessibilityLabel(connectionAccessibilityLabel)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(serverName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(appearanceSettings.currentTheme.foreground))
                        .lineLimit(1)

                    if isMosh {
                        Text("MOSH")
                            .font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(Color(appearanceSettings.currentTheme.accentGreen))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color(appearanceSettings.currentTheme.accentGreen).opacity(0.15), in: .rect(cornerRadius: 4))
                    }
                }

                Text(serverDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Button {
                showTmuxPalette = true
            } label: {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Open tmux command palette")
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                isKeyboardVisible.toggle()
            } label: {
                Image(systemName: isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(isKeyboardVisible ? "Hide keyboard" : "Show keyboard")
            .accessibilityHint("Toggles the terminal software keyboard")
            .accessibilityIdentifier("terminal.keyboard.toggle")
            .keyboardShortcut("k", modifiers: [.command, .shift])

            // Swap — toggle to the previous session (only visible with 2+ sessions)
            if canSwapSession {
                Button {
                    HapticService.lightTap()
                    onSwapSession?()
                } label: {
                    Image(systemName: "rectangle.2.swap")
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Switch to previous session")
                .keyboardShortcut("]", modifiers: [.command, .shift])
            }

            // Minimize — return to server list, keep session alive in carousel
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Return to servers")
            .accessibilityHint("Keeps this terminal session running")
            .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SwiftUI.Color(appearanceSettings.currentTheme.chromeSurface))
    }

    // Floating pill banner — Dynamic Island inspired, centered at top
    private var reconnectingBanner: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .tint(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow))
            Text("Reconnecting")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow).opacity(0.15))
                .overlay(
                    Capsule()
                        .strokeBorder(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow).opacity(0.3), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity)
    }

    // Floating pill banner for disconnected state with reconnect action
    private var disconnectedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11))
                .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentRed))
            Text("Disconnected")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentRed))

            Button {
                Task {
                    if let sshSession = connectionVM.sshSession {
                        await sshSession.reconnect()
                    }
                }
            } label: {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentRed))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .strokeBorder(SwiftUI.Color(appearanceSettings.currentTheme.accentRed).opacity(0.5), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(SwiftUI.Color(appearanceSettings.currentTheme.accentRed).opacity(0.15))
                .overlay(
                    Capsule()
                        .strokeBorder(SwiftUI.Color(appearanceSettings.currentTheme.accentRed).opacity(0.3), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity)
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

    private var connectionAccessibilityLabel: String {
        switch connectionVM.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .sshBootstrap: "Establishing SSH connection"
        case .moshStarting: "Starting Mosh"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case .error: "Connection error"
        }
    }
}
