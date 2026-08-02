import SwiftUI

/// Discoverable actions paired with each active-session row.
struct SessionActionsMenu: View {
    let session: ManagedSession
    let onDuplicate: (UUID) -> Void
    let onClose: (UUID) -> Void

    private var theme: TerminalTheme { AppearanceSettings.shared.currentTheme }

    var body: some View {
        Menu {
            Button {
                onDuplicate(session.id)
            } label: {
                Label("Duplicate Session", systemImage: "plus.square.on.square")
            }

            Button(role: .destructive) {
                onClose(session.id)
            } label: {
                Label("Close Session", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color(theme.secondaryForeground))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Actions for \(session.serverName)")
    }
}
