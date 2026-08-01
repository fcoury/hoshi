import SwiftUI

/// Horizontal scrolling carousel of active session cards, shown above the server list
/// when at least one session is alive. Tapping a card switches to that session's
/// full-screen terminal; long-press context menu allows closing.
struct SessionCarouselView: View {
    let sessions: [ManagedSession]
    let onTap: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    let onClose: (UUID) -> Void

    private var theme: TerminalTheme { AppearanceSettings.shared.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Terminal-style section header with trailing line
            HStack(spacing: 8) {
                Text("ACTIVE SESSIONS (\(sessions.count))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SwiftUI.Color(theme.secondaryForeground))

                Rectangle()
                    .fill(SwiftUI.Color(theme.separator))
                    .frame(height: 0.5)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(sessions) { session in
                        Button {
                                HapticService.mediumTap()
                                onTap(session.id)
                        } label: {
                            SessionCardView(session: session)
                        }
                        .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    onDuplicate(session.id)
                                } label: {
                                    Label("Duplicate Session", systemImage: "plus.square.on.square")
                                }

                                Button("Close Session", role: .destructive) {
                                    onClose(session.id)
                                }
                            }
                            .accessibilityHint("Reopens the active terminal session")
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
    }
}
