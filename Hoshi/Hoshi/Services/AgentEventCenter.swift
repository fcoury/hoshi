import Foundation

/// Main-actor inbox state; event parsing and companion networking stay on dedicated actors.
@MainActor @Observable
final class AgentEventCenter {
    static let shared = AgentEventCenter()

    @ObservationIgnored private let persistence: AgentEventPersistenceStore
    @ObservationIgnored private let notifications: any AgentNotificationDelivering
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var sessionManager: SessionManager?

    private static let notificationSettingKey = "app.gethoshi.agent-notifications-enabled"

    private(set) var events: [AgentInboxEvent]
    private(set) var notificationsEnabled: Bool
    private(set) var notificationError: String?

    var unreadCount: Int {
        events.lazy.filter(\.isUnread).count
    }

    init(
        persistence: AgentEventPersistenceStore = AgentEventPersistenceStore(),
        notifications: (any AgentNotificationDelivering)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.notifications = notifications ?? AgentNotificationService.shared
        self.defaults = defaults
        self.events = persistence.load()
        self.notificationsEnabled = defaults.bool(forKey: Self.notificationSettingKey)
    }

    func attach(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        synchronizeSessionAttention()
    }

    @discardableResult
    func ingest(_ envelope: AgentEventEnvelope, from session: ManagedSession) -> AgentInboxEvent? {
        insert(
            envelope,
            session: session,
            serverID: session.serverID,
            hostname: session.server.hostname,
            origin: .terminal
        )
    }

    @discardableResult
    func ingestCompanion(_ envelope: AgentEventEnvelope) -> AgentInboxEvent? {
        guard envelope.isValid else { return nil }

        let matching = sessionManager?.sessions.filter { session in
            if let sessionID = envelope.sessionID, session.id != sessionID { return false }
            if let serverID = envelope.serverID, session.serverID != serverID { return false }
            if let hostname = envelope.hostname,
               session.server.hostname.caseInsensitiveCompare(hostname) != .orderedSame {
                return false
            }
            if let tmux = envelope.tmuxSession,
               session.tmuxSession != tmux {
                return false
            }
            return true
        } ?? []

        // Never guess between multiple active sessions for an unaffiliated event.
        let session = matching.count == 1 ? matching[0] : nil
        return insert(
            envelope,
            session: session,
            serverID: session?.serverID ?? envelope.serverID,
            hostname: session?.server.hostname ?? envelope.hostname,
            origin: .companion
        )
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationError = nil

        guard enabled else {
            notificationsEnabled = false
            defaults.set(false, forKey: Self.notificationSettingKey)
            await notifications.setBadgeCount(0)
            return
        }

        do {
            let granted = try await notifications.requestAuthorization()
            guard granted else {
                notificationError = "Enable notifications for Hoshi in iOS Settings."
                return
            }
            notificationsEnabled = true
            defaults.set(true, forKey: Self.notificationSettingKey)
            await notifications.setBadgeCount(unreadCount)
        } catch {
            notificationError = error.localizedDescription
        }
    }

    func markRead(eventID: UUID) {
        guard let index = events.firstIndex(where: { $0.id == eventID }), events[index].isUnread else { return }
        events[index].readAt = Date()
        persistence.save(events)
        notifications.remove(eventID: eventID)
        synchronizeSessionAttention()
        Task { await notifications.setBadgeCount(unreadCount) }
    }

    func markSessionRead(sessionID: UUID) {
        var changed = false
        for index in events.indices where events[index].sessionID == sessionID && events[index].isUnread {
            events[index].readAt = Date()
            notifications.remove(eventID: events[index].id)
            changed = true
        }
        guard changed else { return }
        persistence.save(events)
        synchronizeSessionAttention()
        Task { await notifications.setBadgeCount(unreadCount) }
    }

    func markAllRead() {
        var changed = false
        for index in events.indices where events[index].isUnread {
            events[index].readAt = Date()
            notifications.remove(eventID: events[index].id)
            changed = true
        }
        guard changed else { return }
        persistence.save(events)
        synchronizeSessionAttention()
        Task { await notifications.setBadgeCount(0) }
    }

    func remove(eventID: UUID) {
        guard events.contains(where: { $0.id == eventID }) else { return }
        events.removeAll { $0.id == eventID }
        persistence.save(events)
        notifications.remove(eventID: eventID)
        synchronizeSessionAttention()
        Task { await notifications.setBadgeCount(unreadCount) }
    }

    func clear() {
        for event in events {
            notifications.remove(eventID: event.id)
        }
        events.removeAll()
        persistence.save(events)
        synchronizeSessionAttention()
        Task { await notifications.setBadgeCount(0) }
    }

    func synchronizeSessionAttention() {
        guard let sessionManager else { return }
        for session in sessionManager.sessions {
            let unread = events.filter { $0.sessionID == session.id && $0.isUnread }
            session.unreadAgentEventCount = unread.count
            session.agentAttentionKind = unread.max {
                $0.kind.attentionPriority < $1.kind.attentionPriority
            }?.kind
        }
    }

    private func insert(
        _ envelope: AgentEventEnvelope,
        session: ManagedSession?,
        serverID: UUID?,
        hostname: String?,
        origin: AgentEventOrigin
    ) -> AgentInboxEvent? {
        guard envelope.isValid,
              !events.contains(where: { $0.id == envelope.id }) else { return nil }

        let now = Date()
        let requestedDate = envelope.timestamp ?? now
        let createdAt = requestedDate.timeIntervalSince(now) > 300 ? now : requestedDate
        let event = AgentInboxEvent(
            id: envelope.id,
            kind: envelope.kind,
            title: String(envelope.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
            message: envelope.message.map { String($0.prefix(1_000)) },
            createdAt: createdAt,
            serverID: serverID,
            sessionID: session?.id,
            serverName: session?.serverName ?? hostname ?? "Coding Agent",
            hostname: hostname,
            tmuxSession: session?.tmuxSession ?? envelope.tmuxSession,
            origin: origin,
            readAt: nil
        )

        events.insert(event, at: 0)
        events.sort { $0.createdAt > $1.createdAt }
        if events.count > AgentEventPersistenceStore.maximumEvents {
            events.removeLast(events.count - AgentEventPersistenceStore.maximumEvents)
        }
        persistence.save(events)
        synchronizeSessionAttention()

        let shouldNotify = notificationsEnabled
            && (session == nil
                || sessionManager?.activeSessionID != session?.id
                || envelope.kind == .approvalRequested)
        if shouldNotify {
            let count = unreadCount
            Task { [weak self] in
                guard let self,
                      self.notificationsEnabled,
                      self.events.first(where: { $0.id == event.id })?.isUnread == true else {
                    return
                }
                do {
                    try await self.notifications.deliver(event, badgeCount: count)
                    if self.events.first(where: { $0.id == event.id })?.isUnread != true {
                        self.notifications.remove(eventID: event.id)
                    }
                } catch {
                    self.notificationError = error.localizedDescription
                }
            }
        }

        return event
    }
}
