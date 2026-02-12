import Foundation
import Citadel

// Result of starting mosh-server over SSH
struct MoshConnectionInfo {
    let udpPort: UInt16
    let sessionKey: Data
    let serverIP: String
}

// Package managers we can detect on the remote host
enum RemotePackageManager: String, CaseIterable {
    case apt
    case brew
    case yum
    case dnf
    case pacman

    // The install command for mosh-server
    var installCommand: String {
        switch self {
        case .apt: return "sudo apt-get install -y mosh"
        case .brew: return "brew install mosh"
        case .yum: return "sudo yum install -y mosh"
        case .dnf: return "sudo dnf install -y mosh"
        case .pacman: return "sudo pacman -S --noconfirm mosh"
        }
    }
}

// Outcomes of mosh-server detection
enum MoshServerStatus {
    case available(path: String)
    case notFound(packageManager: RemotePackageManager?)
    case notFoundNoPackageManager
}

// Handles SSH-based mosh-server detection, installation, and launch
final class MoshBootstrapService {
    private let client: SSHClient
    private let hostname: String

    init(client: SSHClient, hostname: String) {
        self.client = client
        self.hostname = hostname
    }

    // Check if mosh-server exists on the remote host
    func detectMoshServer() async throws -> MoshServerStatus {
        let output = try await runCommand("which mosh-server 2>/dev/null || echo __NOT_FOUND__")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("__NOT_FOUND__") || trimmed.isEmpty {
            // mosh-server not found — check for a package manager
            let pm = try await detectPackageManager()
            if let pm {
                return .notFound(packageManager: pm)
            }
            return .notFoundNoPackageManager
        }

        return .available(path: trimmed)
    }

    // Detect which package manager is available on the remote host
    func detectPackageManager() async throws -> RemotePackageManager? {
        for pm in RemotePackageManager.allCases {
            let output = try await runCommand("which \(pm.rawValue) 2>/dev/null || echo __NOT_FOUND__")
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains("__NOT_FOUND__") && !trimmed.isEmpty {
                return pm
            }
        }
        return nil
    }

    // Install mosh-server using the detected package manager
    func installMoshServer(using packageManager: RemotePackageManager) async throws {
        let output = try await runCommand(packageManager.installCommand)
        // Verify installation succeeded
        let verifyOutput = try await runCommand("which mosh-server 2>/dev/null || echo __NOT_FOUND__")
        if verifyOutput.contains("__NOT_FOUND__") {
            throw MoshBootstrapError.installFailed(
                reason: "Installation command completed but mosh-server not found. Output: \(output.prefix(200))"
            )
        }
    }

    // Start mosh-server and parse connection info from its output
    // mosh-server prints: MOSH CONNECT <port> <base64-key>
    func startMoshServer() async throws -> MoshConnectionInfo {
        // Start mosh-server with 256-color support
        let output = try await runCommand("mosh-server new -s -c 256 -l LANG=en_US.UTF-8 2>&1")

        // Parse the MOSH CONNECT line
        let (port, keyString) = try MoshBootstrapService.parseMoshConnect(output)

        // Decode the base64 session key
        guard let keyData = Data(base64Encoded: keyString), keyData.count == 16 else {
            throw MoshBootstrapError.invalidSessionKey
        }

        return MoshConnectionInfo(
            udpPort: port,
            sessionKey: keyData,
            serverIP: hostname
        )
    }

    // Parse "MOSH CONNECT <port> <key>" from mosh-server output
    static func parseMoshConnect(_ output: String) throws -> (port: UInt16, key: String) {
        // Look for the MOSH CONNECT line in the output
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("MOSH CONNECT") {
                let parts = trimmed.components(separatedBy: " ")
                guard parts.count >= 4 else { continue }
                guard let port = UInt16(parts[2]) else { continue }
                let key = parts[3]
                return (port: port, key: key)
            }
        }
        throw MoshBootstrapError.noConnectLine(output: String(output.prefix(500)))
    }

    // MARK: - Private

    // Execute a command over SSH and return its output
    private func runCommand(_ command: String) async throws -> String {
        let buffer = try await client.executeCommand(command)
        guard let output = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return ""
        }
        return output
    }
}

enum MoshBootstrapError: LocalizedError {
    case installFailed(reason: String)
    case invalidSessionKey
    case noConnectLine(output: String)
    case sshCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .installFailed(let reason):
            return "Failed to install mosh-server: \(reason)"
        case .invalidSessionKey:
            return "mosh-server returned an invalid session key"
        case .noConnectLine(let output):
            return "Could not find MOSH CONNECT in server output: \(output)"
        case .sshCommandFailed(let reason):
            return "SSH command failed: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .installFailed:
            return "Try installing mosh-server manually on the remote host."
        case .invalidSessionKey:
            return "The mosh-server may be an incompatible version. Try updating it."
        case .noConnectLine:
            return "Ensure mosh-server is properly installed and your user has permission to run it."
        case .sshCommandFailed:
            return "Check your SSH connection and try again."
        }
    }
}
