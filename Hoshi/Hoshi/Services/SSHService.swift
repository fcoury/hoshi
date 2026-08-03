import Foundation
import Citadel
import NIOCore
import NIOSSH
import os.log

private let sshRecoveryLog = Logger(subsystem: "com.hoshi.app.dev", category: "ConnectionRecovery")

// Represents an active SSH terminal session
@MainActor
final class SSHSession: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var recoveryStatus: ConnectionRecoveryStatus = .idle
    @Published var outputBuffer: String = ""
    private var bufferedTerminalOutput = Data()
    private let agentEventDecoder = AgentEventStreamDecoder()

    private(set) var client: SSHClient?
    private(set) var untrustedHostIdentity: SSHHostKeyIdentity?
    private(set) var connectionError: (any Error)?
    private var stdinWriter: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?
    private var ptyReadinessContinuation: CheckedContinuation<Void, Error>?
    private var pendingTerminalSize: (cols: Int, rows: Int)?

    // Command to run inside the PTY after it opens (e.g. tmux attach)
    var initialCommand: String?

    // Raw data callback for feeding bytes directly to the terminal renderer
    var onDataReceived: TerminalDataCallback?
    var onAgentEvent: (@MainActor (AgentEventEnvelope) -> Void)?

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
    private var isAppActive = true
    private var recoveryElapsed: TimeInterval = 0
    private var recoveryStartedAt: Date?

    let server: Server

    init(server: Server, reconnectionPolicy: ReconnectionPolicy = .ssh) {
        self.server = server
        self.reconnectionPolicy = reconnectionPolicy
    }

    // Connect to the server and open an interactive terminal
    func connect(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting
        untrustedHostIdentity = nil
        connectionError = nil

        // Store credentials for reconnection
        storedPassword = password
        storedKeyTag = privateKeyTag

        do {
            let client = try await SSHConnectionService.connect(
                server: server,
                password: password,
                privateKeyTag: privateKeyTag
            )
            adoptBootstrapClient(
                client,
                password: password,
                privateKeyTag: privateKeyTag,
                markConnected: false
            )

            // Open an interactive PTY session
            try await startTerminalSession()

        } catch {
            if error is CancellationError {
                connectionState = .disconnected
                return
            }
            captureUntrustedHostIdentity(from: error)
            connectionError = error
            connectionState = .error(presentedError(for: error).explanation)
        }
    }

    // Connect SSH only (no PTY). Used when tmux detection needs to run first.
    func connectOnly(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting
        untrustedHostIdentity = nil
        connectionError = nil

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
            connectionError = error
            connectionState = .error(presentedError(for: error).explanation)
        }
    }

    // Open the PTY session (call after connectOnly + tmux detection)
    func openTerminal() async throws {
        try await startTerminalSession()
    }

    func adoptBootstrapClient(
        _ client: SSHClient,
        password: String?,
        privateKeyTag: String?,
        markConnected: Bool = true
    ) {
        self.client = client
        self.storedPassword = password
        self.storedKeyTag = privateKeyTag
        self.connectionError = nil
        if markConnected {
            self.connectionState = .connected
            self.recoveryStatus = .idle
        }

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

    func processInboundOutput(_ data: Data) async {
        let result = await agentEventDecoder.ingest(data)
        for event in result.events {
            onAgentEvent?(event)
        }

        guard !result.terminalOutput.isEmpty else { return }
        if let callback = onDataReceived {
            callback(Array(result.terminalOutput))
        } else {
            bufferTerminalOutput(result.terminalOutput)
        }
    }

    // Send data (keystrokes) to the remote terminal
    func send(_ data: Data) async {
        guard connectionState == .connected,
              recoveryStatus == .idle,
              let stdinWriter else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        do {
            try await stdinWriter.write(buffer)
        } catch {
            connectionError = error
            requestReconnect()
        }
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
        isAppActive = false
        recoveryElapsed = 0
        recoveryStartedAt = nil

        sessionTask?.cancel()
        sessionTask = nil
        finishPTYReadiness(throwing: CancellationError())
        stdinWriter = nil
        try? await client?.close()
        client = nil

        // Clear stored credentials
        storedPassword = nil
        storedKeyTag = nil
        bufferedTerminalOutput.removeAll()

        recoveryStatus = .idle
        connectionState = .disconnected
    }

    // Attempt to reconnect after an unexpected disconnect
    func reconnect() async {
        guard !sessionEndedNormally else { return }
        guard !isReconnecting else { return }
        isAppActive = true
        isReconnecting = true
        connectionState = .reconnecting
        recoveryStatus = .reconnecting
        recoveryStartedAt = Date()

        // Clean up the old connection
        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter = nil
        try? await client?.close()
        client = nil

        // Retry for a bounded amount of foreground time.
        var attempt = 0
        var lastError: Error?
        while isAppActive,
              !Task.isCancelled,
              remainingRecoveryBudget > 0 {
            attempt += 1
            sshRecoveryLog.notice("SSH recovery attempt \(attempt, privacy: .public)")
            let delay = attempt == 1
                ? 0
                : min(reconnectionPolicy.delay(forAttempt: attempt - 1), remainingRecoveryBudget)
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                try Task.checkCancellation()
            } catch {
                isReconnecting = false
                pauseRecoveryBudget()
                return
            }

            guard isReconnecting, isAppActive else { return }
            guard remainingRecoveryBudget > 0 else { break }

            do {
                let client = try await ConnectionDeadline.run(
                    timeout: min(reconnectionPolicy.attemptTimeout, max(0.1, remainingRecoveryBudget)),
                    phase: .sshBootstrap
                ) {
                    try await SSHConnectionService.connect(
                        server: self.server,
                        password: self.storedPassword,
                        privateKeyTag: self.storedKeyTag
                    )
                }
                adoptBootstrapClient(
                    client,
                    password: storedPassword,
                    privateKeyTag: storedKeyTag,
                    markConnected: false
                )

                // A transport is not recovered until its PTY is writable.
                try await startTerminalSession()
                isReconnecting = false
                recoveryElapsed = 0
                recoveryStartedAt = nil
                sshRecoveryLog.notice("SSH recovery opened a writable PTY")
                return

            } catch {
                if error is CancellationError {
                    isReconnecting = false
                    pauseRecoveryBudget()
                    return
                }
                lastError = error
                sshRecoveryLog.error("SSH recovery attempt failed: \(String(reflecting: type(of: error)), privacy: .public)")
                if error is SSHHostKeyTrustError {
                    pauseRecoveryBudget()
                    captureUntrustedHostIdentity(from: error)
                    connectionError = error
                    isReconnecting = false
                    recoveryStatus = .unavailable(presentedError(for: error).explanation)
                    connectionState = .error(presentedError(for: error).explanation)
                    return
                }

                sessionTask?.cancel()
                sessionTask = nil
                finishPTYReadiness(throwing: CancellationError())
                stdinWriter = nil
                try? await client?.close()
                client = nil

                // Keep trying until we exhaust attempts
                continue
            }
        }

        // The foreground retry budget was exhausted.
        pauseRecoveryBudget()
        isReconnecting = false
        connectionError = lastError
        let message = "SSH could not reconnect after 60 seconds."
        recoveryStatus = .unavailable(message)
        connectionState = .error(message)
        sshRecoveryLog.error("SSH recovery budget exhausted")
    }

    func retryRecovery() async {
        guard connectionState != .disconnected, !sessionEndedNormally else { return }
        recoveryElapsed = 0
        recoveryStartedAt = nil
        connectionError = nil
        await reconnect()
    }

    func handleAppBackground() {
        isAppActive = false
        pauseRecoveryBudget()
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    // Called when the SSH connection drops unexpectedly
    private func handleDisconnect() {
        // Shell exited normally (user typed 'exit') — don't reconnect
        guard !sessionEndedNormally else { return }
        // Only auto-reconnect if we were previously connected (not user-initiated disconnect)
        guard connectionState == .connected || connectionState == .reconnecting else { return }
        guard !isReconnecting else { return }

        // Start reconnection in background
        requestReconnect()
    }

    private func requestReconnect() {
        guard isAppActive, reconnectTask == nil, !sessionEndedNormally else { return }
        sshRecoveryLog.notice("SSH recovery requested")
        reconnectTask = Task { [weak self] in
            await self?.reconnect()
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
        }
    }

    private var remainingRecoveryBudget: TimeInterval {
        let activeElapsed = recoveryStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, reconnectionPolicy.foregroundBudget - recoveryElapsed - activeElapsed)
    }

    private func pauseRecoveryBudget() {
        if let recoveryStartedAt {
            recoveryElapsed += Date().timeIntervalSince(recoveryStartedAt)
        }
        recoveryStartedAt = nil
    }

    // MARK: - Private

    private func startTerminalSession() async throws {
        guard let client else { throw ConnectionCoordinatorError.bootstrapUnavailable }
        sessionEndedNormally = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ptyReadinessContinuation = continuation
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

                        let terminalEnvironment = TerminalIdentity.environment.map {
                            SSHChannelRequestEvent.EnvironmentRequest(
                                wantReply: false,
                                name: $0.name,
                                value: $0.value
                            )
                        }

                        try await client.withPTY(
                            ptyRequest,
                            environment: terminalEnvironment
                        ) { [weak self] inbound, outbound in
                            guard let self else { return }

                            // Recovery is complete only after the PTY accepts input.
                            await MainActor.run {
                                self.stdinWriter = outbound
                                self.connectionError = nil
                                self.connectionState = .connected
                                self.recoveryStatus = .idle
                                self.finishPTYReadiness()
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
                                        await self.processInboundOutput(Data(bytes))
                                    }
                                case .stderr(let buffer):
                                    if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                                        await self.processInboundOutput(Data(bytes))
                                    }
                                }
                            }

                            // PTY stream ended — shell exited normally.
                            await MainActor.run {
                                self.sessionEndedNormally = true
                                self.connectionState = .disconnected
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.finishPTYReadiness(throwing: error)
                            if self.sessionEndedNormally {
                                if self.connectionState != .disconnected {
                                    self.connectionState = .disconnected
                                }
                            } else if !Task.isCancelled, !self.isReconnecting {
                                self.connectionError = error
                                self.connectionState = .error(self.presentedError(for: error).explanation)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionTask?.cancel()
                self.finishPTYReadiness(throwing: CancellationError())
            }
        }
    }

    private func finishPTYReadiness(throwing error: Error? = nil) {
        guard let continuation = ptyReadinessContinuation else { return }
        ptyReadinessContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // Keep the typed transport error available while providing a concise terminal-state summary.
    private func captureUntrustedHostIdentity(from error: Error) {
        guard let hostKeyError = error as? SSHHostKeyTrustError,
              case .untrusted(let identity) = hostKeyError else {
            return
        }
        untrustedHostIdentity = identity
    }

    private func presentedError(for error: any Error) -> ErrorPresentation {
        ErrorPresentation.classify(error, context: .connection(server: server))
    }
}

// Conform to TerminalSession protocol
extension SSHSession: TerminalSession {}
