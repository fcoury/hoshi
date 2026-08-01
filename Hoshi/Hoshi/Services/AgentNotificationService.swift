import Foundation
import UserNotifications

@MainActor
protocol AgentNotificationDelivering: AnyObject {
    func requestAuthorization() async throws -> Bool
    func deliver(_ event: AgentInboxEvent, badgeCount: Int) async throws
    func remove(eventID: UUID)
    func setBadgeCount(_ count: Int) async
}

@MainActor
final class AgentNotificationService: NSObject, AgentNotificationDelivering {
    static let shared = AgentNotificationService()

    private nonisolated static let category = "HOSHI_AGENT_EVENT"
    private nonisolated static let openAction = "HOSHI_OPEN_TERMINAL"
    private nonisolated static let markReadAction = "HOSHI_MARK_READ"

    private let center: UNUserNotificationCenter

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
    }

    func configure() {
        center.delegate = self

        let open = UNNotificationAction(
            identifier: Self.openAction,
            title: "Open Terminal",
            options: [.foreground]
        )
        let markRead = UNNotificationAction(
            identifier: Self.markReadAction,
            title: "Mark Read",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [open, markRead],
                intentIdentifiers: []
            )
        ])
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(_ event: AgentInboxEvent, badgeCount: Int) async throws {
        let content = Self.makeContent(
            for: event,
            badgeCount: badgeCount,
            protectDetails: AppLockService.shared.isEnabled
        )

        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    static func makeContent(
        for event: AgentInboxEvent,
        badgeCount: Int,
        protectDetails: Bool
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if protectDetails {
            content.title = "Agent \(event.kind.title)"
            content.subtitle = "Hoshi"
            content.body = "Unlock Hoshi to review this agent event."
        } else {
            content.title = event.title
            content.subtitle = "\(event.serverName) · \(event.kind.title)"
            content.body = event.message ?? "Open Hoshi to check this agent."
        }
        content.sound = .default
        content.badge = NSNumber(value: badgeCount)
        content.threadIdentifier = event.serverID?.uuidString ?? event.hostname ?? "hoshi-agent-events"
        content.categoryIdentifier = Self.category
        content.userInfo = [
            "eventID": event.id.uuidString,
            "deepLink": deepLink(for: event).url.absoluteString,
        ]
        return content
    }

    func remove(eventID: UUID) {
        let identifiers = [eventID.uuidString]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    private static func deepLink(for event: AgentInboxEvent) -> AgentDeepLink {
        if let sessionID = event.sessionID {
            return .session(sessionID: sessionID, eventID: event.id)
        }
        if let serverID = event.serverID {
            return .server(serverID: serverID, eventID: event.id)
        }
        return .inbox(eventID: event.id)
    }
}

extension AgentNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        if response.actionIdentifier == Self.markReadAction,
           let value = userInfo["eventID"] as? String,
           let eventID = UUID(uuidString: value) {
            await MainActor.run {
                AgentEventCenter.shared.markRead(eventID: eventID)
            }
            return
        }

        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let value = userInfo["deepLink"] as? String,
              let url = URL(string: value) else { return }

        await MainActor.run {
            _ = AgentDeepLinkRouter.shared.route(url)
        }
    }
}
