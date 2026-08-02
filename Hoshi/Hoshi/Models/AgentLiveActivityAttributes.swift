import ActivityKit
import Foundation

/// Shared by the app and widget extension; never stores terminal output, event messages, or credentials.
struct AgentLiveActivityAttributes: ActivityAttributes, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case running
        case completed
        case needsAttention
        case approvalRequested

        var title: String {
            switch self {
            case .running: "Agent Running"
            case .completed: "Completed"
            case .needsAttention: "Needs Attention"
            case .approvalRequested: "Approval Requested"
            }
        }

        var systemImage: String {
            switch self {
            case .running: "terminal"
            case .completed: "checkmark.circle.fill"
            case .needsAttention: "exclamationmark.circle.fill"
            case .approvalRequested: "hand.raised.fill"
            }
        }
    }

    struct ContentState: Codable, Hashable, Sendable {
        var status: Status
        var displayName: String
        var tmuxSession: String?
        var attentionCount: Int
        var latestEventID: UUID?
        var updatedAt: Date
        var detailsAreHidden: Bool
    }

    let sessionID: UUID
    let startedAt: Date

    func deepLink(for state: ContentState) -> URL? {
        var components = URLComponents()
        components.scheme = "hoshi"
        components.host = "session"
        components.path = "/\(sessionID.uuidString)"
        if let eventID = state.latestEventID {
            components.queryItems = [URLQueryItem(name: "event", value: eventID.uuidString)]
        }
        return components.url
    }
}
