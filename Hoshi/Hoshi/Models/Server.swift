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
    var useMosh: Bool
    var lastConnected: Date?
    // When set, this entry auto-attaches to the named tmux session on connect
    var tmuxSession: String?

    init(
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        useMosh: Bool = false,
        tmuxSession: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.useMosh = useMosh
        self.tmuxSession = tmuxSession
    }
}
