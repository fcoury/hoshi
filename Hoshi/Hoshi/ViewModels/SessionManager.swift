import Foundation

// Orchestrates all active terminal sessions, enforcing the max-sessions limit
// and managing thumbnail capture on session switches.
@MainActor @Observable
final class SessionManager {
    static let maxSessions = 5

    private(set) var sessions: [ManagedSession] = []
    var activeSessionID: UUID?

    // Track which session triggered the tmux picker
    var tmuxPickerSession: ManagedSession?

    var activeSession: ManagedSession? {
        sessions.first { $0.id == activeSessionID }
    }

    var hasActiveSessions: Bool {
        !sessions.isEmpty
    }

    // Create a new managed session for the given server.
    // Returns nil if the max session limit is reached.
    func createSession(for server: Server) -> ManagedSession? {
        guard sessions.count < Self.maxSessions else { return nil }
        let session = ManagedSession(server: server)
        sessions.append(session)
        return session
    }

    // Close and remove a session by ID
    func closeSession(id: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        await session.connectionVM.disconnect()
        sessions.remove(at: index)

        // If the closed session was active, clear the active ID
        if activeSessionID == id {
            activeSessionID = nil
        }
    }

    // Switch to a session: capture thumbnail of current, then set the new active ID
    func switchTo(sessionID: UUID) {
        // Capture thumbnail of the session we're leaving
        if let current = activeSession {
            current.captureThumbnail()
        }
        activeSessionID = sessionID
    }

    // Return to the server list: capture thumbnail and clear active session
    func returnToServerList() {
        if let current = activeSession {
            current.captureThumbnail()
        }
        activeSessionID = nil
    }

    // Forward scene-active to all sessions for reconnect handling
    func handleSceneActive() {
        for session in sessions {
            session.connectionVM.handleSceneActive()
        }
    }

    // Capture thumbnail of the active session when entering background
    func handleSceneBackground() {
        if let current = activeSession {
            current.captureThumbnail()
        }
    }
}
