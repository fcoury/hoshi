import Foundation

enum AgentEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case completed
    case needsAttention = "needs_attention"
    case approvalRequested = "approval_requested"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .completed: "Completed"
        case .needsAttention: "Needs Attention"
        case .approvalRequested: "Approval Requested"
        }
    }

    var systemImage: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        case .approvalRequested: "hand.raised.fill"
        }
    }

    var attentionPriority: Int {
        switch self {
        case .completed: 1
        case .needsAttention: 2
        case .approvalRequested: 3
        }
    }
}

/// Versioned, transport-neutral event emitted by a remote coding-agent hook.
struct AgentEventEnvelope: Codable, Equatable, Sendable {
    static let supportedVersion = 1

    let version: Int
    let id: UUID
    let kind: AgentEventKind
    let title: String
    let message: String?
    let timestamp: Date?
    let hostname: String?
    let serverID: UUID?
    let sessionID: UUID?
    let tmuxSession: String?

    init(
        version: Int = supportedVersion,
        id: UUID = UUID(),
        kind: AgentEventKind,
        title: String,
        message: String? = nil,
        timestamp: Date? = nil,
        hostname: String? = nil,
        serverID: UUID? = nil,
        sessionID: UUID? = nil,
        tmuxSession: String? = nil
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.timestamp = timestamp
        self.hostname = hostname
        self.serverID = serverID
        self.sessionID = sessionID
        self.tmuxSession = tmuxSession
    }

    var isValid: Bool {
        version == Self.supportedVersion
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.utf8.count <= 512
            && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (message?.utf8.count ?? 0) <= 4_096
            && (hostname?.utf8.count ?? 0) <= 255
            && (tmuxSession?.utf8.count ?? 0) <= 256
            && !(hostname?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false)
            && !(tmuxSession?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false)
    }
}

enum AgentEventOrigin: String, Codable, Sendable {
    case terminal
    case companion
}

struct AgentInboxEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: AgentEventKind
    let title: String
    let message: String?
    let createdAt: Date
    let serverID: UUID?
    let sessionID: UUID?
    let serverName: String
    let hostname: String?
    let tmuxSession: String?
    let origin: AgentEventOrigin
    var readAt: Date?

    var isUnread: Bool { readAt == nil }
}
