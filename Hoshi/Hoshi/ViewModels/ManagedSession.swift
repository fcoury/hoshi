import Foundation
import UIKit

// Wraps a ConnectionViewModel with session identity, thumbnail, and surface reference.
// Each ManagedSession represents one active terminal session in the multi-session manager.
@MainActor @Observable
final class ManagedSession: Identifiable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let createdAt: Date
    let connectionVM: ConnectionViewModel
    let server: Server

    var lastAccessedAt: Date
    var tmuxSession: String?
    var unreadAgentEventCount = 0
    var agentAttentionKind: AgentEventKind?
    var thumbnail: UIImage?
    // Own the actual Ghostty surface so switching sessions never discards screen state.
    @ObservationIgnored
    var surfaceView: GhosttyTerminalSurfaceView?

    var connectionState: ConnectionState { connectionVM.connectionState }
    var hasActiveSession: Bool { connectionVM.hasActiveSession }
    var transportPolicy: ConnectionTransportPolicy { server.transportPolicy }
    var isMosh: Bool {
        if connectionVM.sshSession != nil { return false }
        if connectionVM.moshSession != nil { return true }
        return transportPolicy != .ssh
    }

    init(
        server: Server,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        tmuxSession: String? = nil
    ) {
        self.id = id
        self.serverID = server.id
        self.serverName = server.name
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt ?? createdAt
        self.tmuxSession = tmuxSession ?? server.tmuxSession
        self.server = server
        self.connectionVM = ConnectionViewModel()
    }

    var persistedDescriptor: PersistedSessionDescriptor {
        PersistedSessionDescriptor(
            id: id,
            serverID: serverID,
            serverName: serverName,
            transportPolicy: transportPolicy,
            tmuxSession: tmuxSession,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
    }

    // Snapshot the terminal surface at half resolution for thumbnail use
    func captureThumbnail() {
        thumbnail = surfaceView?.captureSnapshot()
    }

    func redactThumbnail() {
        let size = CGSize(width: 320, height: 190)
        let renderer = UIGraphicsImageRenderer(size: size)
        thumbnail = renderer.image { context in
            AppearanceSettings.shared.currentTheme.background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            let image = UIImage(systemName: "lock.shield", withConfiguration: configuration)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            guard let image else { return }
            image.draw(at: CGPoint(
                x: (size.width - image.size.width) / 2,
                y: (size.height - image.size.height) / 2
            ))
        }
    }
}
