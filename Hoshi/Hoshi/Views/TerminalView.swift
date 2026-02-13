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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showToolbarEditor) {
            ToolbarEditView(onSave: {
                // GhosttyTerminalView reloads toolbar buttons after dismissal.
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
                    onDismiss?()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(SwiftUI.Color(appearanceSettings.currentTheme.chromeSurface))
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
