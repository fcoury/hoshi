import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
@preconcurrency import CCryptoBoringSSL

// Represents an active SSH terminal session
@MainActor
final class SSHSession: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var outputBuffer: String = ""

    private(set) var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?
    private var pendingTerminalSize: (cols: Int, rows: Int)?

    // Command to run inside the PTY after it opens (e.g. tmux attach)
    var initialCommand: String?

    // Raw data callback for feeding bytes directly to the terminal renderer
    var onDataReceived: TerminalDataCallback?

    // Stored credentials for reconnection after disconnect
    private var storedPassword: String?
    private var storedKeyTag: String?

    // Reconnection state
    private var isReconnecting = false
    private var reconnectTask: Task<Void, Never>?
    private let maxReconnectAttempts = 3
    private let reconnectDelay: TimeInterval = 2.0

    let server: Server

    init(server: Server) {
        self.server = server
    }

    // Connect to the server and open an interactive terminal
    func connect(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting

        // Store credentials for reconnection
        storedPassword = password
        storedKeyTag = privateKeyTag

        do {
            // Build the authentication method
            let authMethod = try buildAuthMethod(
                server: server,
                password: password,
                privateKeyTag: privateKeyTag
            )

            // Establish SSH connection
            let client = try await SSHClient.connect(
                host: server.hostname,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )

            self.client = client

            // Watch for disconnection — trigger automatic reconnection
            client.onDisconnect { [weak self] in
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }

            connectionState = .connected

            // Open an interactive PTY session
            await startTerminalSession()

        } catch {
            let errorMessage = mapError(error)
            connectionState = .error(errorMessage.errorDescription ?? "Unknown error")
        }
    }

    // Connect SSH only (no PTY). Used when tmux detection needs to run first.
    func connectOnly(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting

        // Store credentials for reconnection
        storedPassword = password
        storedKeyTag = privateKeyTag

        do {
            let authMethod = try buildAuthMethod(
                server: server,
                password: password,
                privateKeyTag: privateKeyTag
            )

            let client = try await SSHClient.connect(
                host: server.hostname,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )

            self.client = client

            // Watch for disconnection — trigger automatic reconnection
            client.onDisconnect { [weak self] in
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }

            connectionState = .connected

        } catch {
            let errorMessage = mapError(error)
            connectionState = .error(errorMessage.errorDescription ?? "Unknown error")
        }
    }

    // Open the PTY session (call after connectOnly + tmux detection)
    func openTerminal() async {
        await startTerminalSession()
    }

    // Send data (keystrokes) to the remote terminal
    func send(_ data: Data) async {
        guard let stdinWriter else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        try? await stdinWriter.write(buffer)
    }

    // Send a string to the remote terminal
    func sendString(_ string: String) async {
        guard let data = string.data(using: .utf8) else { return }
        await send(data)
    }

    // Resize the terminal
    func resize(cols: Int, rows: Int) async {
        pendingTerminalSize = (cols, rows)
        guard let stdinWriter else { return }
        try? await stdinWriter.changeSize(
            cols: cols,
            rows: rows,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    // Disconnect from the server (user-initiated)
    func disconnect() async {
        // Cancel any pending reconnection
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false

        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter = nil
        try? await client?.close()
        client = nil

        // Clear stored credentials
        storedPassword = nil
        storedKeyTag = nil

        connectionState = .disconnected
    }

    // Attempt to reconnect after an unexpected disconnect
    func reconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        connectionState = .reconnecting

        // Clean up the old connection
        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter = nil
        try? await client?.close()
        client = nil

        // Retry with exponential backoff
        for attempt in 1...maxReconnectAttempts {
            let delay = reconnectDelay * Double(attempt)
            try? await Task.sleep(for: .seconds(delay))

            guard isReconnecting else { return }

            do {
                let authMethod = try buildAuthMethod(
                    server: server,
                    password: storedPassword,
                    privateKeyTag: storedKeyTag
                )

                let client = try await SSHClient.connect(
                    host: server.hostname,
                    port: server.port,
                    authenticationMethod: authMethod,
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )

                self.client = client

                // Watch for future disconnections
                client.onDisconnect { [weak self] in
                    Task { @MainActor in
                        self?.handleDisconnect()
                    }
                }

                connectionState = .connected
                isReconnecting = false

                // Re-open the PTY session
                await startTerminalSession()
                return

            } catch {
                // Keep trying until we exhaust attempts
                continue
            }
        }

        // All attempts failed
        isReconnecting = false
        connectionState = .disconnected
    }

    // Called when the SSH connection drops unexpectedly
    private func handleDisconnect() {
        // Only auto-reconnect if we were previously connected (not user-initiated disconnect)
        guard connectionState == .connected || connectionState == .reconnecting else { return }
        guard !isReconnecting else { return }

        // Start reconnection in background
        reconnectTask = Task { [weak self] in
            await self?.reconnect()
        }
    }

    // MARK: - Private

    private func startTerminalSession() async {
        guard let client else { return }

        sessionTask = Task { [weak self] in
            guard let self else { return }

            do {
                let initialSize = await MainActor.run {
                    self.pendingTerminalSize ?? (cols: 80, rows: 24)
                }

                // Open a PTY with xterm-256color for full color support
                let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: initialSize.cols,
                    terminalRowHeight: initialSize.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([
                        .ECHO: 1,
                        .ICANON: 1,
                        .ISIG: 1,
                        .ICRNL: 1,
                        .ONLCR: 1,
                        .OPOST: 1,
                    ])
                )

                try await client.withPTY(ptyRequest) { [weak self] inbound, outbound in
                    guard let self else { return }

                    // Store the stdin writer so we can send keystrokes
                    await MainActor.run {
                        self.stdinWriter = outbound
                    }

                    // Re-apply latest requested size in case it changed after PTY request creation.
                    if let size = await MainActor.run(body: { self.pendingTerminalSize }) {
                        try? await outbound.changeSize(
                            cols: size.cols,
                            rows: size.rows,
                            pixelWidth: 0,
                            pixelHeight: 0
                        )
                    }

                    // Send initial command if set (e.g. tmux attach/new)
                    if let cmd = await MainActor.run(body: { self.initialCommand }) {
                        var cmdBuffer = ByteBuffer()
                        cmdBuffer.writeString(cmd + "\n")
                        try? await outbound.write(cmdBuffer)
                    }

                    // Read output from the remote terminal
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer):
                            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                                let callback = await MainActor.run { self.onDataReceived }
                                // Feed raw bytes to terminal renderer if callback is set
                                if let callback {
                                    callback(bytes)
                                } else if let text = String(bytes: bytes, encoding: .utf8) {
                                    await MainActor.run {
                                        self.outputBuffer.append(text)
                                    }
                                }
                            }
                        case .stderr(let buffer):
                            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                                let callback = await MainActor.run { self.onDataReceived }
                                if let callback {
                                    callback(bytes)
                                } else if let text = String(bytes: bytes, encoding: .utf8) {
                                    await MainActor.run {
                                        self.outputBuffer.append(text)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.connectionState = .error("Terminal session ended: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // Build the appropriate authentication method based on server config
    private func buildAuthMethod(
        server: Server,
        password: String?,
        privateKeyTag: String?
    ) throws -> SSHAuthenticationMethod {
        switch server.authMethod {
        case .password:
            guard let password else {
                throw SSHConnectionError.authenticationFailed(method: "password")
            }
            return .passwordBased(username: server.username, password: password)

        case .key:
            guard let tag = privateKeyTag else {
                throw SSHConnectionError.keyNotFound
            }

            guard let keyData = try KeychainService.shared.retrievePrivateKey(withTag: tag) else {
                throw SSHConnectionError.keyNotFound
            }

            // Try Ed25519 first (32 bytes raw representation)
            if keyData.count == 32 {
                let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
                return .ed25519(
                    username: server.username,
                    privateKey: privateKey
                )
            }

            // Parse PKCS#1 DER to extract RSA components (n, e, d)
            let components = try SSHKeyService.parseRSAPrivateKeyDER(keyData)

            // Convert raw byte arrays to BoringSSL BIGNUMs
            let modulus = CCryptoBoringSSL_BN_bin2bn(
                components.n, components.n.count, nil
            )!
            let publicExponent = CCryptoBoringSSL_BN_bin2bn(
                components.e, components.e.count, nil
            )!
            let privateExponent = CCryptoBoringSSL_BN_bin2bn(
                components.d, components.d.count, nil
            )!

            let rsaKey = Insecure.RSA.PrivateKey(
                privateExponent: privateExponent,
                publicExponent: publicExponent,
                modulus: modulus
            )
            return .rsa(
                username: server.username,
                privateKey: rsaKey
            )
        }
    }

    // Map raw errors to user-facing SSHConnectionError
    private func mapError(_ error: Error) -> SSHConnectionError {
        let message = error.localizedDescription.lowercased()

        if message.contains("connection refused") {
            return .connectionRefused(hostname: server.hostname, port: server.port)
        } else if message.contains("authentication") || message.contains("auth") {
            return .authenticationFailed(method: server.authMethod.rawValue)
        } else if message.contains("timeout") || message.contains("timed out") {
            return .timeout(hostname: server.hostname)
        } else if message.contains("network") || message.contains("unreachable") || message.contains("no route") {
            return .networkUnreachable
        } else if message.contains("host key") {
            return .hostKeyVerificationFailed
        } else if message.contains("channel") {
            return .channelOpenFailed
        }

        return .unexpected(message: error.localizedDescription)
    }
}

// Conform to TerminalSession protocol
extension SSHSession: TerminalSession {}
