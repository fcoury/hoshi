import SwiftUI

/// Session card for the carousel: terminal thumbnail with a metadata bar below.
///
/// Visual state reflects the underlying connection:
/// - **Status dot** pulses during transient states (connecting, reconnecting).
/// - **Card opacity** fades to 50% when disconnected or errored.
/// - **Protocol badge** is colored green (Mosh) or blue (SSH) from the theme palette.
struct SessionCardView: View {
    let session: ManagedSession

    private let cardWidth: CGFloat = 260
    private let thumbnailHeight: CGFloat = 140
    private let metadataHeight: CGFloat = 40
    private let appearanceSettings = AppearanceSettings.shared
    private var theme: TerminalTheme { appearanceSettings.currentTheme }

    @State private var statusDotPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail area
            ZStack(alignment: .topTrailing) {
                thumbnailContent
                    .frame(width: cardWidth, height: thumbnailHeight)
                    .clipped()

                // Status dot — pulses during connecting/reconnecting
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(statusDotPulsing ? 1.3 : 1.0)
                    .opacity(statusDotPulsing ? 0.7 : 1.0)
                    .onAppear {
                        if isConnecting {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                statusDotPulsing = true
                            }
                        }
                    }
                    .onChange(of: isConnecting) { _, pulsing in
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
                    .padding(6)
            }

            // Metadata bar
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.serverName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        // Tmux session badge — themed cyan
                        if let tmux = session.tmuxSession {
                            Text(tmux)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(SwiftUI.Color(theme.accentCyan))
                        }

                        // Protocol badge — themed green/blue
                        Text(session.isMosh ? "MOSH" : "SSH")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(SwiftUI.Color(session.isMosh ? theme.accentGreen : theme.accentBlue))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(width: cardWidth, height: metadataHeight)
            .background(SwiftUI.Color(appearanceSettings.currentTheme.chromeSurface))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SwiftUI.Color(theme.separator), lineWidth: 0.5)
        )
        // Fade disconnected/error sessions
        .opacity(isDisconnected ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.6), value: isDisconnected)
    }

    private var isDisconnected: Bool {
        switch session.connectionState {
        case .disconnected, .error:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail = session.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // No thumbnail placeholder: theme background with connecting indicator
            ZStack {
                SwiftUI.Color(appearanceSettings.currentTheme.background)

                if session.connectionState == .connected {
                    Text("Terminal active")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var isConnecting: Bool {
        switch session.connectionState {
        case .connecting, .sshBootstrap, .moshStarting, .reconnecting:
            return true
        default:
            return false
        }
    }

    private var statusColor: SwiftUI.Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .sshBootstrap, .moshStarting: return .yellow
        case .reconnecting: return .orange
        case .disconnected, .error: return .red
        }
    }
}
