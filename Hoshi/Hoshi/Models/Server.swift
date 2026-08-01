import Foundation
import SwiftData

// Authentication method for SSH connections
enum AuthMethod: String, Codable, CaseIterable {
    case password
    case key
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
        moshUDPPortRange: String? = nil
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
    }
}
