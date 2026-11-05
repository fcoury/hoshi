import Foundation
import Citadel
import Network

// Result of starting mosh-server over SSH
struct MoshConnectionInfo: Sendable {
    let udpPort: UInt16
    let sessionKey: Data
    let sessionKeyBase64: String
    let serverIP: String
    /// mosh-server's process ID, so a later session can stop it if this one is abandoned.
    var serverPID: Int32? = nil
}

// Package managers we can detect on the remote host
enum RemotePackageManager: String, CaseIterable, Sendable {
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
enum MoshServerStatus: Sendable {
    case available(path: String)
    case notFound(packageManager: RemotePackageManager?)
    case notFoundNoPackageManager
}

// Handles SSH-based mosh-server detection, installation, and launch
final class MoshBootstrapService {
    private let client: SSHClient
    private let hostname: String
    private let configuredServerPath: String?
    private let portRange: MoshPortRange?

    init(
        client: SSHClient,
        hostname: String,
        configuredServerPath: String? = nil,
        portRange: MoshPortRange? = nil
    ) {
        self.client = client
        self.hostname = hostname
        self.configuredServerPath = configuredServerPath
        self.portRange = portRange
    }

    // Check if mosh-server exists on the remote host
    func detectMoshServer() async throws -> MoshServerStatus {
        let executable = configuredServerPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = executable.flatMap { $0.isEmpty ? nil : $0 } ?? "mosh-server"
        let output = try await runCommand("command -v \(Self.shellEscape(command)) 2>/dev/null || echo __NOT_FOUND__")
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
    /// Starts mosh-server. `replacingServerPID` is a mosh-server this session left running
    /// earlier (the app was killed before it could shut it down); it is stopped first.
    func startMoshServer(
        initialCommand: String? = nil,
        replacingServerPID: Int32? = nil
    ) async throws -> MoshConnectionInfo {
        let output: String
        do {
            output = try await runCommand(Self.serverLaunchCommand(
                configuredServerPath: configuredServerPath,
                portRange: portRange,
                initialCommand: initialCommand,
                replacingServerPID: replacingServerPID
            ))
        } catch let failure as SSHClient.CommandFailed {
            // The launch command reports mosh-server's status itself, so this means the
            // wrapper shell failed; its output is lost.
            throw MoshBootstrapError.serverFailedToStart(
                MoshLaunchFailure(launchOutput: "", exitCode: failure.exitCode)
            )
        }

        // Parse the MOSH CONNECT line
        let port: UInt16
        let keyString: String
        do {
            (port, keyString) = try MoshBootstrapService.parseMoshConnect(output)
        } catch {
            throw MoshBootstrapError.serverFailedToStart(MoshLaunchFailure(launchOutput: output))
        }
        // mosh-server binds only to the address SSH arrived on (`new -s`). Aim UDP at
        // that exact address instead of letting the socket resolve the name again, which
        // can pick another address family or drop a link-local IPv6 interface scope.
        let reportedServerIP = Self.parseServerIPFromSSHConnection(output)
        let hostname = self.hostname
        let candidates = await Task.detached {
            Self.resolveNumericHosts(hostname, port: port)
        }.value
        let serverIP = Self.udpHost(serverIP: reportedServerIP, hostname: hostname, candidates: candidates)

        // mosh key on the wire is unpadded 22-char base64.
        guard let keyData = MoshBootstrapService.decodeMoshSessionKey(keyString) else {
            throw MoshBootstrapError.invalidSessionKey
        }

        return MoshConnectionInfo(
            udpPort: port,
            sessionKey: keyData,
            sessionKeyBase64: keyString,
            serverIP: serverIP,
            serverPID: Self.parseServerPID(output)
        )
    }

    /// mosh-server reports "[mosh-server detached, pid = 1234]" once it is running.
    static func parseServerPID(_ output: String) -> Int32? {
        guard let range = output.range(of: #"\[mosh-server detached, pid = (\d+)\]"#, options: .regularExpression) else {
            return nil
        }
        return Int32(output[range].filter(\.isNumber))
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

    // Parse server-side SSH_CONNECTION line emitted as:
    // MOSH SSH_CONNECTION <client_ip> <client_port> <server_ip> <server_port>
    static func parseServerIPFromSSHConnection(_ output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("MOSH SSH_CONNECTION ") else { continue }
            let parts = trimmed.components(separatedBy: " ")
            guard parts.count == 6 else { continue }
            return parts[4]
        }
        return nil
    }

    /// The resolved address of `hostname` that is the address mosh-server bound to,
    /// keeping its client-side scope (`fe80::1%en0`). Falls back to `hostname` when the
    /// server's address isn't one of them, such as behind NAT.
    static func udpHost(serverIP: String?, hostname: String, candidates: [String]) -> String {
        guard let serverIP, let target = normalizedAddress(serverIP) else { return hostname }
        return candidates.first { normalizedAddress($0) == target } ?? hostname
    }

    /// The bytes of an IP literal, ignoring any `%scope` (the server reports its own
    /// interface) and treating IPv4-mapped IPv6 as IPv4.
    static func normalizedAddress(_ literal: String) -> Data? {
        let bare = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal
        if let ipv4 = IPv4Address(bare) { return ipv4.rawValue }
        if let ipv6 = IPv6Address(bare) { return ipv6.asIPv4?.rawValue ?? ipv6.rawValue }
        return nil
    }

    /// Numeric forms of every UDP address `hostname` resolves to. Scoped IPv6 results
    /// keep their interface (`fe80::1%en0`).
    static func resolveNumericHosts(_ hostname: String, port: UInt16) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, String(port), &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var hosts: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                let host = String(cString: buffer)
                if !hosts.contains(host) { hosts.append(host) }
            }
            cursor = info.pointee.ai_next
        }
        return hosts
    }

    static func decodeMoshSessionKey(_ key: String) -> Data? {
        guard key.count == 22 else { return nil }
        guard key.range(of: #"^[A-Za-z0-9/+]{22}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Data(base64Encoded: key + "==")
    }

    /// Seconds mosh-server keeps running without hearing from Hoshi: long enough to resume
    /// after a weekend in the background, short enough that abandoned shells go away.
    static let orphanedServerTimeout = 72 * 60 * 60

    static func serverLaunchCommand(
        configuredServerPath: String?,
        portRange: MoshPortRange?,
        initialCommand: String?,
        replacingServerPID: Int32? = nil
    ) -> String {
        let binary = configuredServerPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = shellEscape(binary.flatMap { $0.isEmpty ? nil : $0 } ?? "mosh-server")
        let rangeArgument = portRange.map { " -p \(shellEscape($0.argument))" } ?? ""
        let commandArgument = initialCommand.map { " -- sh -lc \(shellEscape($0))" } ?? ""
        let terminalEnvironment = TerminalIdentity.environment
            .map { " -l \(shellEscape("\($0.name)=\($0.value)"))" }
            .joined()
        // A client that vanishes without shutting down (the app was killed in the background)
        // must not leave the shell running forever. Respect a timeout the user already set.
        let networkTimeout = "MOSH_SERVER_NETWORK_TMOUT=\"${MOSH_SERVER_NETWORK_TMOUT:-\(orphanedServerTimeout)}\""
        // Stop only a process that is still a mosh-server; kill only reaches our own processes.
        let stopPrevious = replacingServerPID.map {
            "case \"$(ps -p \($0) -o comm= 2>/dev/null)\" in *mosh-server*) kill \($0) 2>/dev/null;; esac; "
        } ?? ""
        let command = "\(stopPrevious)[ -n \"$SSH_CONNECTION\" ] && printf \"\\nMOSH SSH_CONNECTION %s\\n\" \"$SSH_CONNECTION\"; \(networkTimeout) \(executable) new -s -c 256 -l LANG=en_US.UTF-8\(terminalEnvironment)\(rangeArgument)\(commandArgument); printf \"\\n\(MoshLaunchFailure.exitMarker) %s\\n\" \"$?\""
        return "sh -lc \(shellEscape(command)) 2>&1"
    }

    // MARK: - Private

    // Execute a command over SSH and return its output
    private func runCommand(_ command: String) async throws -> String {
        try Task.checkCancellation()
        let buffer = try await client.executeCommand(command)
        try Task.checkCancellation()
        guard let output = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return ""
        }
        return output
    }

    static func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum MoshBootstrapError: LocalizedError {
    case installFailed(reason: String)
    case invalidSessionKey
    case noConnectLine(output: String)
    case serverFailedToStart(MoshLaunchFailure)
    case sshCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .installFailed(let reason):
            return "Failed to install mosh-server: \(reason)"
        case .invalidSessionKey:
            return "mosh-server returned an invalid session key"
        case .noConnectLine(let output):
            return "Could not find MOSH CONNECT in server output: \(output)"
        case .serverFailedToStart(let failure):
            var description = failure.summary
            if let exitCode = failure.exitCode { description += " Exit status \(exitCode)." }
            if !failure.output.isEmpty { description += "\nServer output:\n\(failure.output)" }
            return description
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
        case .serverFailedToStart(let failure):
            return failure.recovery
        case .sshCommandFailed:
            return "Check your SSH connection and try again."
        }
    }
}
