import Foundation
import Citadel
import NIOCore
import NIOSSH

// Represents an active SSH terminal session
@MainActor
final class SSHSession: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var outputBuffer: String = ""
    private var bufferedTerminalOutput = Data()

    private(set) var client: SSHClient?
    private(set) var untrustedHostIdentity: SSHHostKeyIdentity?
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

    // Tracks whether the PTY stream ended normally (user typed 'exit')
    // so onDisconnect doesn't race and trigger a reconnect
    private(set) var sessionEndedNormally = false

    // Reconnection state
    private var isReconnecting = false
    private var reconnectTask: Task<Void, Never>?
    private let reconnectionPolicy: ReconnectionPolicy

    let server: Server

    init(server: Server, reconnectionPolicy: ReconnectionPolicy = .ssh) {
        self.server = server
        self.reconnectionPolicy = reconnectionPolicy
    }

    // Connect to the server and open an interactive terminal
    func connect(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting
        untrustedHostIdentity = nil

        // Store credentials for reconnection
        storedPassword = password
        storedKeyTag = privateKeyTag

        do {
            let client = try await SSHConnectionService.connect(
                server: server,
                password: password,
                privateKeyTag: privateKeyTag
            )
            adoptBootstrapClient(client, password: password, privateKeyTag: privateKeyTag)

            // Open an interactive PTY session
            await startTerminalSession()

        } catch {
            if error is CancellationError {
                connectionState = .disconnected
                return
            }
            captureUntrustedHostIdentity(from: error)
            let errorMessage = mapError(error)
            connectionState = .error(errorMessage.errorDescription ?? "Unknown error")
        }
    }

    // Connect SSH only (no PTY). Used when tmux detection needs to run first.
    func connectOnly(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting
        untrustedHostIdentity = nil

        // Store credentials for reconnection
        storedPassword = password
        storedKeyTag = privateKeyTag

        do {
            let client = try await SSHConnectionService.connect(
                server: server,
                password: password,
                privateKeyTag: privateKeyTag
            )
            adoptBootstrapClient(client, password: password, privateKeyTag: privateKeyTag)

        } catch {
            if error is CancellationError {
                connectionState = .disconnected
                return
            }
            captureUntrustedHostIdentity(from: error)
            let errorMessage = mapError(error)
            connectionState = .error(errorMessage.errorDescription ?? "Unknown error")
        }
    }

    // Open the PTY session (call after connectOnly + tmux detection)
    func openTerminal() async {
        await startTerminalSession()
    }

    func adoptBootstrapClient(
        _ client: SSHClient,
        password: String?,
        privateKeyTag: String?
    ) {
        self.client = client
        self.storedPassword = password
        self.storedKeyTag = privateKeyTag
        self.connectionState = .connected

        client.onDisconnect { [weak self] in
            Task { @MainActor in
                self?.handleDisconnect()
            }
        }
    }

    func consumeBufferedTerminalOutput() -> Data {
        let output = bufferedTerminalOutput
        bufferedTerminalOutput.removeAll(keepingCapacity: true)
        outputBuffer = ""
        return output
    }

    func bufferTerminalOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        bufferedTerminalOutput.append(data)
        if let text = String(data: data, encoding: .utf8) {
            outputBuffer.append(text)
        }
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
        bufferedTerminalOutput.removeAll()

        connectionState = .disconnected
    }

    // Attempt to reconnect after an unexpected disconnect
    func reconnect() async {
        guard !sessionEndedNormally else { return }
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
        for attempt in 1...reconnectionPolicy.maximumAttempts {
            let delay = reconnectionPolicy.delay(forAttempt: attempt)
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
            } catch {
                isReconnecting = false
                return
            }

            guard isReconnecting else { return }

            do {
                let client = try await SSHConnectionService.connect(
                    server: server,
                    password: storedPassword,
                    privateKeyTag: storedKeyTag
                )
                adoptBootstrapClient(client, password: storedPassword, privateKeyTag: storedKeyTag)
                isReconnecting = false

                // Re-open the PTY session
                await startTerminalSession()
                return

            } catch {
                if error is SSHHostKeyTrustError {
                    captureUntrustedHostIdentity(from: error)
                    let errorMessage = mapError(error)
                    isReconnecting = false
                    connectionState = .error(errorMessage.errorDescription ?? "Unknown error")
                    return
                }

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
        // Shell exited normally (user typed 'exit') — don't reconnect
        guard !sessionEndedNormally else { return }
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
        sessionEndedNormally = false

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
                                } else {
                                    await MainActor.run {
                                        self.bufferTerminalOutput(Data(bytes))
                                    }
                                }
                            }
                        case .stderr(let buffer):
                            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                                let callback = await MainActor.run { self.onDataReceived }
                                if let callback {
                                    callback(bytes)
                                } else {
                                    await MainActor.run {
                                        self.bufferTerminalOutput(Data(bytes))
                                    }
                                }
                            }
                        }
                    }

                    // PTY stream ended — shell exited normally.
                    // Set the flag and state NOW, before withPTY does channel
                    // cleanup and fires onDisconnect.
                    await MainActor.run {
                        self.sessionEndedNormally = true
                        self.connectionState = .disconnected
                    }
                }
            } catch {
                await MainActor.run {
                    if self.sessionEndedNormally {
                        // Cleanup error after normal exit — keep .disconnected
                        if self.connectionState != .disconnected {
                            self.connectionState = .disconnected
                        }
                    } else if !Task.isCancelled {
                        self.connectionState = .error("Terminal session ended: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // Map raw errors to user-facing SSHConnectionError
    private func captureUntrustedHostIdentity(from error: Error) {
        guard let hostKeyError = error as? SSHHostKeyTrustError,
              case .untrusted(let identity) = hostKeyError else {
            return
        }
        untrustedHostIdentity = identity
    }

    private func mapError(_ error: Error) -> SSHConnectionError {
        if let hostKeyError = error as? SSHHostKeyTrustError {
            return .hostKeyVerificationFailed(reason: hostKeyError.localizedDescription)
        }
        if let connectionError = error as? SSHConnectionError {
            return connectionError
        }

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
            return .hostKeyVerificationFailed(reason: error.localizedDescription)
        } else if message.contains("channel") {
            return .channelOpenFailed
        }

        return .unexpected(message: error.localizedDescription)
    }
}

// Conform to TerminalSession protocol
extension SSHSession: TerminalSession {}
