import SwiftUI

/// Compact, privacy-preserving presentation of an active terminal session.
///
/// The row deliberately avoids live terminal thumbnails. Connection state is always
/// communicated with text and color, while transport and agent attention remain
/// available at a glance.
struct SessionRowView: View {
    let session: ManagedSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appearanceSettings = AppearanceSettings.shared
    private var theme: TerminalTheme { appearanceSettings.currentTheme }

    @State private var statusDotPulsing = false

    var body: some View {
        HStack(spacing: 12) {
            sessionIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(session.serverName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(theme.foreground))
                        .lineLimit(1)

                    if let tmux = session.tmuxSession {
                        Text(tmux)
                            .font(.caption2.weight(.medium).monospaced())
                            .foregroundStyle(Color(theme.accentCyan))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(theme.accentCyan).opacity(0.14), in: .rect(cornerRadius: 4))
                            .lineLimit(1)
                    }

                    AgentAttentionBadge(
                        count: session.unreadAgentEventCount,
                        kind: session.agentAttentionKind
                    )
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .scaleEffect(statusDotPulsing ? 1.3 : 1)
                        .opacity(statusDotPulsing ? 0.65 : 1)

                    Text(session.connectionState.conciseLabel)
                        .foregroundStyle(statusColor)

                    Text("·")
                        .foregroundStyle(Color(theme.secondaryForeground))

                    Text(session.lastAccessedAt, style: .relative)
                        .foregroundStyle(Color(theme.secondaryForeground))
                }
                .font(.caption.monospaced())
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            transportBadge
        }
        .padding(.vertical, 5)
        .opacity(session.connectionState.isUnavailable ? 0.72 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: session.connectionState.isUnavailable)
        .onAppear(perform: updatePulse)
        .onChange(of: session.connectionState.isTransient) { _, _ in
            updatePulse()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sessionIcon: some View {
        Image(systemName: session.isMosh ? "antenna.radiowaves.left.and.right" : "terminal")
            .font(.body.weight(.medium))
            .foregroundStyle(transportColor)
            .frame(width: 42, height: 42)
            .background(transportColor.opacity(0.13), in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var transportBadge: some View {
        Text(session.isMosh ? "MOSH" : "SSH")
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(transportColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(transportColor.opacity(0.14), in: .rect(cornerRadius: 5))
            .accessibilityLabel(session.isMosh ? "Mosh transport" : "SSH transport")
    }

    private var transportColor: Color {
        Color(session.isMosh ? theme.accentGreen : theme.accentBlue)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected:
            Color(theme.accentGreen)
        case .connecting, .sshBootstrap, .moshStarting:
            Color(theme.accentYellow)
        case .reconnecting:
            Color(theme.accentYellow)
        case .disconnected, .error:
            Color(theme.accentRed)
        }
    }

    private var accessibilityLabel: String {
        var components = [
            session.serverName,
            session.connectionState.conciseLabel,
            session.isMosh ? "Mosh" : "SSH",
        ]
        if let tmux = session.tmuxSession {
            components.append("tmux \(tmux)")
        }
        if session.unreadAgentEventCount > 0 {
            components.append("\(session.unreadAgentEventCount) unread agent events")
        }
        return components.joined(separator: ", ")
    }

    private func updatePulse() {
        guard session.connectionState.isTransient, !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) {
                statusDotPulsing = false
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            statusDotPulsing = true
        }
    }
}
