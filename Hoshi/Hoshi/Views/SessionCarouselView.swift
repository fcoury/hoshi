import SwiftUI

// Horizontal scrolling carousel of active session cards.
struct SessionCarouselView: View {
    let sessions: [ManagedSession]
    let onTap: (UUID) -> Void
    let onClose: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            Text("ACTIVE SESSIONS (\(sessions.count))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(sessions) { session in
                        SessionCardView(session: session)
                            .onTapGesture { onTap(session.id) }
                            .contextMenu {
                                Button("Close Session", role: .destructive) {
                                    onClose(session.id)
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
    }
}
