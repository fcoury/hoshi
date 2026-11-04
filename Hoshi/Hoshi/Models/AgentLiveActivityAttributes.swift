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

        /// Whether the person is expected to act, which turns the call to
        /// action into "Reply".
        var wantsReply: Bool {
            self == .needsAttention || self == .approvalRequested
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
        /// The latest event's title, such as "Claude needs input". Only set
        /// when details are visible; never contains terminal output.
        var headline: String?
        /// Herdr agent counts on the host. All zero without Herdr.
        var workingCount: Int
        var blockedCount: Int
        var doneCount: Int

        init(
            status: Status,
            displayName: String,
            tmuxSession: String?,
            attentionCount: Int,
            latestEventID: UUID?,
            updatedAt: Date,
            detailsAreHidden: Bool,
            headline: String? = nil,
            workingCount: Int = 0,
            blockedCount: Int = 0,
            doneCount: Int = 0
        ) {
            self.status = status
            self.displayName = displayName
            self.tmuxSession = tmuxSession
            self.attentionCount = attentionCount
            self.latestEventID = latestEventID
            self.updatedAt = updatedAt
            self.detailsAreHidden = detailsAreHidden
            self.headline = headline
            self.workingCount = workingCount
            self.blockedCount = blockedCount
            self.doneCount = doneCount
        }

        private enum CodingKeys: String, CodingKey {
            case status, displayName, tmuxSession, attentionCount, latestEventID, updatedAt
            case detailsAreHidden, headline, workingCount, blockedCount, doneCount
        }

        // Activities started by an older build decode without the newer fields.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            displayName = try container.decode(String.self, forKey: .displayName)
            tmuxSession = try container.decodeIfPresent(String.self, forKey: .tmuxSession)
            attentionCount = try container.decode(Int.self, forKey: .attentionCount)
            latestEventID = try container.decodeIfPresent(UUID.self, forKey: .latestEventID)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            detailsAreHidden = try container.decode(Bool.self, forKey: .detailsAreHidden)
            headline = try container.decodeIfPresent(String.self, forKey: .headline)
            workingCount = try container.decodeIfPresent(Int.self, forKey: .workingCount) ?? 0
            blockedCount = try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
            doneCount = try container.decodeIfPresent(Int.self, forKey: .doneCount) ?? 0
        }

        var hasAgentCounts: Bool { workingCount + blockedCount + doneCount > 0 }

        /// Agents waiting on a prompt outrank a finished event that is still unread.
        var displayStatus: Status {
            if blockedCount > 0, status == .running || status == .completed { return .needsAttention }
            return status
        }

        /// The main line, written for a glance.
        var primaryText: String {
            if !detailsAreHidden, let headline, !headline.isEmpty { return headline }
            switch displayStatus {
            case .approvalRequested: return "Approval requested"
            case .needsAttention:
                return blockedCount > 1 ? "\(blockedCount) agents need input" : "Agent needs input"
            case .completed: return "Agent finished"
            case .running:
                if workingCount > 0 {
                    return workingCount == 1 ? "1 agent working" : "\(workingCount) agents working"
                }
                return "Connected"
            }
        }

        /// Where it is happening; hidden while details are private.
        var secondaryText: String? {
            guard !detailsAreHidden else { return nil }
            return [displayName, tmuxSession].compactMap { $0 }.joined(separator: " · ")
        }

        var actionTitle: String { displayStatus.wantsReply ? "Reply" : "Open" }
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
