import Foundation
import Citadel

// A single tmux session parsed from `tmux list-sessions`
struct TmuxSessionInfo: Identifiable {
    let name: String
    let windows: Int
    let isAttached: Bool

    var id: String { name }
}

// The user's choice from the tmux session picker
enum TmuxChoice {
    case attach(TmuxSessionInfo)
    case newSession
    case skip
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
            "tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null || echo __NO_SESSIONS__"
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // No tmux server running or no sessions
        if trimmed.contains("__NO_SESSIONS__") || trimmed.isEmpty {
            return []
        }

        // Parse each line: "name|windows|attached"
        return trimmed
            .components(separatedBy: "\n")
            .compactMap { line -> TmuxSessionInfo? in
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "|")
                guard parts.count == 3,
                      !parts[0].isEmpty,
                      let windows = Int(parts[1]) else {
                    return nil
                }
                let attached = parts[2] == "1"
                return TmuxSessionInfo(name: parts[0], windows: windows, isAttached: attached)
            }
    }

    // Build the shell command to attach to an existing session
    static func attachCommand(sessionName: String) -> String {
        "tmux attach -t \(shellEscape(sessionName))"
    }

    // Build the shell command to create a new tmux session
    static func newSessionCommand() -> String {
        "tmux new-session"
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
