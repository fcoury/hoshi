import SwiftUI

// Full terminal emulator view using Ghostty.
struct TerminalView: View {
    @Bindable var connectionVM: ConnectionViewModel
    var managedSession: ManagedSession?
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private let appearanceSettings = AppearanceSettings.shared

    // Font size state for pinch-to-zoom (initialized from settings)
    @State private var fontSize: CGFloat = AppearanceSettings.shared.fontSize

    // Toolbar edit sheet
    @State private var showToolbarEditor = false

    // Keyboard visibility for explicit show/hide control
    @State private var isKeyboardVisible = true

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
                appearanceSettings: appearanceSettings,
                fontSize: $fontSize,
                showToolbarEditor: $showToolbarEditor,
                keyboardVisible: $isKeyboardVisible,
                onSurfaceReady: { surfaceView in
                    // Capture weak reference to the surface for thumbnail snapshots
                    managedSession?.surfaceView = surfaceView
                }
            )
        }
        .animation(.spring(duration: 0.35), value: connectionVM.connectionState)
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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showToolbarEditor) {
            ToolbarEditView(onSave: {
                // GhosttyTerminalView reloads toolbar buttons after dismissal.
            })
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
        HStack {
            // Connection status indicator — pulses during transient states
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .scaleEffect(statusDotPulsing ? 1.3 : 1.0)
                .opacity(statusDotPulsing ? 0.7 : 1.0)
                .animation(.easeInOut(duration: 0.4), value: statusColor)
                .onChange(of: isTransientState) { _, pulsing in
                    if pulsing {
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
                    if isTransientState {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            statusDotPulsing = true
                        }
                    }
                }

            Text(serverName)
                .font(.system(size: 15, weight: .semibold))

            Text(serverDetail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            // Mosh indicator — themed green
            if isMosh {
                Text("MOSH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentGreen))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(SwiftUI.Color(appearanceSettings.currentTheme.accentGreen).opacity(0.15))
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

            // Minimize — return to server list, keep session alive in carousel
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
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
}
