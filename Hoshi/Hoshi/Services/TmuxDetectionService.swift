import Foundation
import Citadel

// A single tmux session parsed from `tmux list-sessions`
struct TmuxSessionInfo: Identifiable, Equatable, Sendable {
    let name: String
    let windows: Int
    let isAttached: Bool
    let lastActivity: Date?
    let createdAt: Date?

    init(
        name: String,
        windows: Int,
        isAttached: Bool,
        lastActivity: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.name = name
        self.windows = windows
        self.isAttached = isAttached
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    var id: String { name }
}

// The user's choice from the tmux session picker
enum TmuxChoice: Sendable {
    case attach(TmuxSessionInfo)
    case newSession
    case newNamedSession(String)
    case skip
    case cancel
}

// Detects tmux on a remote host and lists active sessions
final class TmuxDetectionService {
    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    // Check if tmux is installed on the remote host
    func isTmuxAvailable() async throws -> Bool {
        let output = try await runCommand("which tmux 2>/dev/null || echo __NOT_FOUND__")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.contains("__NOT_FOUND__") && !trimmed.isEmpty
    }

    // List active tmux sessions using a structured format string
    func listSessions() async throws -> [TmuxSessionInfo] {
        let output = try await runCommand(
            "tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}|#{session_created}' 2>/dev/null || echo __NO_SESSIONS__"
        )
        return Self.parseSessionList(output)
    }

    static func parseSessionList(_ output: String) -> [TmuxSessionInfo] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // No tmux server running or no sessions
        if trimmed.contains("__NO_SESSIONS__") || trimmed.isEmpty {
            return []
        }

        // Parse each line: "name|windows|attached|last activity|created".
        return trimmed
            .components(separatedBy: "\n")
            .compactMap { line -> TmuxSessionInfo? in
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "|")
                guard parts.count == 5,
                      !parts[0].isEmpty,
                      let windows = Int(parts[1]) else {
                    return nil
                }
                let attached = parts[2] == "1"
                let activity = TimeInterval(parts[3]).map(Date.init(timeIntervalSince1970:))
                let created = TimeInterval(parts[4]).map(Date.init(timeIntervalSince1970:))
                return TmuxSessionInfo(
                    name: parts[0],
                    windows: windows,
                    isAttached: attached,
                    lastActivity: activity,
                    createdAt: created
                )
            }
            .sorted {
                switch ($0.lastActivity, $1.lastActivity) {
                case let (left?, right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
    }

    // Build the shell command to attach to an existing session
    static func attachCommand(sessionName: String) -> String {
        "tmux attach -t \(shellEscape(sessionName))"
    }

    // Build the shell command to create a new tmux session
    static func newSessionCommand(sessionName: String? = nil) -> String {
        guard let sessionName,
              !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "tmux new-session"
        }
        return "tmux new-session -s \(shellEscape(sessionName))"
    }

    static func isValidSessionName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= 100
            && !trimmed.contains(":")
            && !trimmed.contains(".")
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    // MARK: - Private

    private func runCommand(_ command: String) async throws -> String {
        let buffer = try await client.executeCommand(command)
        guard let output = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return ""
        }
        return output
    }

    // Escape a session name for safe shell usage
    private static func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
