import SwiftUI

// Individual session card for the carousel: thumbnail + metadata bar.
struct SessionCardView: View {
    let session: ManagedSession

    private let cardWidth: CGFloat = 200
    private let thumbnailHeight: CGFloat = 100
    private let metadataHeight: CGFloat = 40
    private let appearanceSettings = AppearanceSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail area
            ZStack(alignment: .topTrailing) {
                thumbnailContent
                    .frame(width: cardWidth, height: thumbnailHeight)
                    .clipped()

                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .padding(6)
            }

            // Metadata bar
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.serverName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        // Tmux session badge
                        if let tmux = session.tmuxSession {
                            Text(tmux)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }

                        // Protocol badge
                        Text(session.isMosh ? "MOSH" : "SSH")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(session.isMosh ? .green : .secondary)
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
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
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

    private var statusColor: SwiftUI.Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .sshBootstrap, .moshStarting: return .yellow
        case .reconnecting: return .orange
        case .disconnected, .error: return .red
        }
    }
}
