import Foundation
import SwiftData

// Authentication method for SSH connections
enum AuthMethod: String, Codable, CaseIterable {
    case password
    case key
}

enum RemoteClipboardAccessPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case allow
    case deny

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: "Ask Every Time"
        case .allow: "Always Allow"
        case .deny: "Never Allow"
        }
    }
}

@Model
final class Server {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    // Keychain tag of the SSH key explicitly selected for this connection.
    var keyID: String?
    var useMosh: Bool
    var isFavorite: Bool = false
    var lastConnected: Date?
    // When set, this entry auto-attaches to the named tmux session on connect
    var tmuxSession: String?
    // Optional raw values preserve compatibility with profiles saved before routing policies existed.
    var transportPolicyRawValue: String?
    var tmuxPolicyRawValue: String?
    var moshServerPath: String?
    var moshUDPPortRange: String?
    // Optional storage keeps existing SwiftData profiles readable and defaults them to asking.
    var remoteClipboardReadPolicyRawValue: String?
    var remoteClipboardWritePolicyRawValue: String?

    // Ports are identifiers, not localized quantities; never insert grouping separators.
    var endpoint: String {
        "\(hostname):\(String(port))"
    }

    var loginEndpoint: String {
        "\(username)@\(endpoint)"
    }

    var transportPolicy: ConnectionTransportPolicy {
        get {
            guard let transportPolicyRawValue,
                  let policy = ConnectionTransportPolicy(rawValue: transportPolicyRawValue) else {
                return useMosh ? .mosh : .ssh
            }
            return policy
        }
        set {
            transportPolicyRawValue = newValue.rawValue
            useMosh = newValue != .ssh
        }
    }

    var tmuxPolicy: TmuxConnectionPolicy {
        get {
            guard let tmuxPolicyRawValue,
                  let policy = TmuxConnectionPolicy(rawValue: tmuxPolicyRawValue) else {
                return tmuxSession == nil ? .alwaysAsk : .autoAttachLast
            }
            return policy
        }
        set { tmuxPolicyRawValue = newValue.rawValue }
    }

    var remoteClipboardReadPolicy: RemoteClipboardAccessPolicy {
        get {
            remoteClipboardReadPolicyRawValue.flatMap(RemoteClipboardAccessPolicy.init(rawValue:)) ?? .ask
        }
        set { remoteClipboardReadPolicyRawValue = newValue.rawValue }
    }

    var remoteClipboardWritePolicy: RemoteClipboardAccessPolicy {
        get {
            remoteClipboardWritePolicyRawValue.flatMap(RemoteClipboardAccessPolicy.init(rawValue:)) ?? .ask
        }
        set { remoteClipboardWritePolicyRawValue = newValue.rawValue }
    }

    init(
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        keyID: String? = nil,
        useMosh: Bool = false,
        isFavorite: Bool = false,
        tmuxSession: String? = nil,
        transportPolicy: ConnectionTransportPolicy? = nil,
        tmuxPolicy: TmuxConnectionPolicy? = nil,
        moshServerPath: String? = nil,
        moshUDPPortRange: String? = nil,
        remoteClipboardReadPolicy: RemoteClipboardAccessPolicy? = nil,
        remoteClipboardWritePolicy: RemoteClipboardAccessPolicy? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyID = keyID
        self.useMosh = transportPolicy.map { $0 != .ssh } ?? useMosh
        self.isFavorite = isFavorite
        self.tmuxSession = tmuxSession
        self.transportPolicyRawValue = transportPolicy?.rawValue
        self.tmuxPolicyRawValue = tmuxPolicy?.rawValue
        self.moshServerPath = moshServerPath
        self.moshUDPPortRange = moshUDPPortRange
        self.remoteClipboardReadPolicyRawValue = remoteClipboardReadPolicy?.rawValue
        self.remoteClipboardWritePolicyRawValue = remoteClipboardWritePolicy?.rawValue
    }
}
