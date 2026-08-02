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
    @ObservationIgnored
    private let persistenceStore: SessionPersistenceStore
    @ObservationIgnored
    private let agentEventCenter: AgentEventCenter?
    private var hasRestoredPersistedSessions = false

    init(
        persistenceStore: SessionPersistenceStore = SessionPersistenceStore(),
        agentEventCenter: AgentEventCenter? = nil
    ) {
        self.persistenceStore = persistenceStore
        self.agentEventCenter = agentEventCenter
        agentEventCenter?.attach(sessionManager: self)
    }

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
        configureAgentMonitoring(for: session)
        promoteSessionToFront(session)
        agentEventCenter?.synchronizeSessionAttention()
        persistSessionDescriptors()
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
        agentEventCenter?.synchronizeSessionAttention()
        persistSessionDescriptors()
    }

    // Toggle to the previous (MRU) session — called by the swap button and 2-finger swipe
    func switchToPrevious() {
        guard sessions.count >= 2 else { return }
        let previousSession = sessions[1]
        switchTo(sessionID: previousSession.id)
    }

    // Switch to a session: capture thumbnail of current, then set the new active ID
    func switchTo(sessionID: UUID) {
        // Capture thumbnail of the session we're leaving
        if let current = activeSession {
            current.captureThumbnail()
        }

        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[index]
        promoteSessionToFront(session)
        activeSessionID = sessionID
        agentEventCenter?.markSessionRead(sessionID: sessionID)
        persistSessionDescriptors()
    }

    // Return to the server list: capture thumbnail and clear active session.
    // If the session is disconnected (user typed 'exit'), remove it from
    // the carousel. If still connected (X button minimize), keep it alive.
    func returnToServerList() {
        let shouldRemove: Bool
        if let current = activeSession {
            current.captureThumbnail()
            shouldRemove = (current.connectionState == .disconnected)
        } else {
            shouldRemove = false
        }
        let removingID = activeSessionID
        activeSessionID = nil
        if shouldRemove, let id = removingID {
            sessions.removeAll { $0.id == id }
        }
        agentEventCenter?.synchronizeSessionAttention()
        persistSessionDescriptors()
    }

    // Forward scene-active to all sessions for reconnect handling
    func handleSceneActive() {
        activeSession?.captureThumbnail()
        for session in sessions {
            session.connectionVM.handleSceneActive()
        }
    }

    // Capture thumbnail of the active session when entering background
    func handleSceneBackground() {
        if let current = activeSession {
            current.redactThumbnail()
        }
        persistSessionDescriptors()
    }

    func restoreSessions(using servers: [Server]) -> [ManagedSession] {
        guard !hasRestoredPersistedSessions, !servers.isEmpty, sessions.isEmpty else { return [] }
        hasRestoredPersistedSessions = true

        let profiles = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let restored = persistenceStore.load()
            .prefix(Self.maxSessions)
            .compactMap { descriptor -> ManagedSession? in
                guard let server = profiles[descriptor.serverID] else { return nil }
                let session = ManagedSession(
                    server: server,
                    id: descriptor.id,
                    createdAt: descriptor.createdAt,
                    lastAccessedAt: descriptor.lastAccessedAt,
                    tmuxSession: descriptor.tmuxSession
                )
                configureAgentMonitoring(for: session)
                return session
            }

        sessions = restored
        agentEventCenter?.synchronizeSessionAttention()
        persistSessionDescriptors()
        return restored
    }

    func recordSessionUpdate(_ session: ManagedSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        persistSessionDescriptors()
    }

    func preferSSH(
        for session: ManagedSession,
        persistedServer: Server,
        save: () throws -> Void
    ) throws {
        guard persistedServer.id == session.serverID else {
            throw SessionTransportPreferenceError.serverProfileUnavailable(session.serverName)
        }
        guard sessions.contains(where: { $0.id == session.id }) else {
            throw SessionTransportPreferenceError.sessionUnavailable(session.serverName)
        }

        let previousPolicy = persistedServer.transportPolicyRawValue
        let previousMoshPreference = persistedServer.useMosh
        persistedServer.transportPolicy = .ssh

        do {
            try save()
        } catch {
            persistedServer.transportPolicyRawValue = previousPolicy
            persistedServer.useMosh = previousMoshPreference
            throw error
        }

        for activeSession in sessions where activeSession.serverID == persistedServer.id {
            guard activeSession.server !== persistedServer else { continue }
            activeSession.server.transportPolicy = .ssh
        }
        persistSessionDescriptors()
    }

    private func promoteSessionToFront(_ session: ManagedSession) {
        session.lastAccessedAt = Date()

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard index != 0 else { return }
            let existing = sessions.remove(at: index)
            sessions.insert(existing, at: 0)
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func persistSessionDescriptors() {
        persistenceStore.save(sessions.map(\.persistedDescriptor))
    }

    private func configureAgentMonitoring(for session: ManagedSession) {
        guard agentEventCenter != nil else { return }
        session.connectionVM.onAgentEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.agentEventCenter?.ingest(event, from: session)
        }
    }
}

enum SessionTransportPreferenceError: LocalizedError, Equatable {
    case serverProfileUnavailable(String)
    case sessionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .serverProfileUnavailable(let serverName):
            "The saved server profile for \(serverName) is no longer available."
        case .sessionUnavailable(let serverName):
            "The terminal session for \(serverName) is no longer active."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .serverProfileUnavailable:
            "Recreate the server profile, then choose SSH in its connection settings."
        case .sessionUnavailable:
            "Reconnect to the server and try again."
        }
    }
}
