import Foundation
import UIKit

// Wraps a ConnectionViewModel with session identity, thumbnail, and surface reference.
// Each ManagedSession represents one active terminal session in the multi-session manager.
@MainActor @Observable
final class ManagedSession: Identifiable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let isMosh: Bool
    let createdAt: Date
    let connectionVM: ConnectionViewModel

    var tmuxSession: String?
    var thumbnail: UIImage?
    weak var surfaceView: GhosttyTerminalSurfaceView?

    var connectionState: ConnectionState { connectionVM.connectionState }
    var hasActiveSession: Bool { connectionVM.hasActiveSession }

    init(server: Server) {
        self.id = UUID()
        self.serverID = server.id
        self.serverName = server.name
        self.isMosh = server.useMosh
        self.createdAt = Date()
        self.tmuxSession = server.tmuxSession
        self.connectionVM = ConnectionViewModel()
    }

    // Snapshot the terminal surface at half resolution for thumbnail use
    func captureThumbnail() {
        thumbnail = surfaceView?.captureSnapshot()
    }
}
