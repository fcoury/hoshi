import Foundation
import Citadel
import NIOCore
import Network
import os.log
import QuartzCore

private let sspLog = Logger(subsystem: "com.hoshi.app.dev", category: "SSP")
private let recoveryLog = Logger(subsystem: "com.hoshi.app.dev", category: "ConnectionRecovery")

// Full mosh session: SSH bootstrap -> mosh-server detection/launch -> UDP communication
@MainActor
final class MoshSession: ObservableObject {
    private static let inputTraceEnabled = ProcessInfo.processInfo.environment["HOSHI_INPUT_TRACE"] == "1"
    private static let sspTraceEnabled = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var recoveryStatus: ConnectionRecoveryStatus = .idle
    @Published var outputBuffer: String = ""
    /// Smoothed SSP round-trip time; nil until the server echoes a timestamp.
    @Published private(set) var roundTripTime: TimeInterval?
    private var roundTripEstimator = MoshRoundTripEstimator()
    private var bufferedTerminalOutput = Data()
    private let agentEventDecoder = AgentEventStreamDecoder()

    // Mosh-specific state exposed to ViewModel for UI decisions
    @Published var moshServerStatus: MoshServerStatus?
    @Published var detectedPackageManager: RemotePackageManager?
    private(set) var untrustedHostIdentity: SSHHostKeyIdentity?
    private(set) var connectionError: (any Error)?

    let server: Server

    // Raw data callback for feeding bytes directly to the terminal renderer
    var onDataReceived: TerminalDataCallback?
    var onAgentEvent: (@MainActor (AgentEventEnvelope) -> Void)?

    private var sshClient: SSHClient?
    private var udpConnection: (any MoshUDPTransport)?
    private var protocolEngine: MoshProtocolEngine?
    private var networkMonitor = NetworkMonitorService()
    private let reconnectionPolicy: ReconnectionPolicy
    private let makeUDPConnection: @MainActor (String, UInt16) -> any MoshUDPTransport

    private var receiveTask: Task<Void, Never>?
    private var transmitTask: Task<Void, Never>?
    private let transmitSignal = MoshTransmitSignal()
    private var networkWatchTask: Task<Void, Never>?
    private var startupProbeTask: Task<Void, Never>?
    private var startupReadinessContinuation: AsyncStream<Void>.Continuation?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryElapsed: TimeInterval = 0
    private var recoveryStartedAt: Date?
    private var isAppActive = true
    private var transportGeneration = UUID()
    private var udpHost: String?
    private var udpPort: UInt16?
    private var pendingTerminalSize: (cols: Int, rows: Int)?
    /// Sent on connect when no view has reported a size yet (a session restored in the
    /// background). mosh-server starts the shell only once it receives a client state, and
    /// exits after 60 seconds without one. The view's real size replaces it.
    static let initialTerminalSize = (cols: 80, rows: 24)

    /// mosh marks the last state of a session with this number, in either direction.
    static let shutdownStateNum = MoshStateSync.shutdownStateNum

    /// Set once the server reported that its shell exited, so the silence that
    /// follows isn't mistaken for a network drop and retried.
    private(set) var sessionEndedNormally = false

    /// The current mosh-server's process ID, as it reported at launch.
    private(set) var serverPID: Int32?
    /// A mosh-server left running by an earlier connection of this session, stopped when
    /// the next one launches.
    var replacingServerPID: Int32?

    /// The server's PID while it may still be running: not after it acknowledged our
    /// shutdown or ended the session itself.
    var runningServerPID: Int32? {
        stateSync.clientShutdownAcknowledged || sessionEndedNormally ? nil : serverPID
    }

    /// SSP state for the current mosh-server; survives socket replacement during recovery.
    private var stateSync = MoshStateSync()
    private var consecutiveDatagramFailures = 0
    /// Set by `disconnect()`, so output still being decoded never reaches the terminal.
    private var outputClosed = false

    private var debugSendInstructionCount = 0
    private var debugSendDatagramCount = 0
    private var debugReceiveDatagramCount = 0
    private var debugUnauthenticatedDatagramCount = 0
    private var debugDecryptSuccessCount = 0
    private var debugInstructionDecodeCount = 0
    private var debugHostOutputCount = 0
    private var debugHostByteCount = 0

    struct DebugStats {
        let sendInstructions: Int
        let sendDatagrams: Int
        let receiveDatagrams: Int
        let decryptSuccesses: Int
        let decodedInstructions: Int
        let decodedHostOutputs: Int
        let decodedHostBytes: Int
    }

    var debugStats: DebugStats {
        DebugStats(
            sendInstructions: debugSendInstructionCount,
            sendDatagrams: debugSendDatagramCount,
            receiveDatagrams: debugReceiveDatagramCount,
            decryptSuccesses: debugDecryptSuccessCount,
            decodedInstructions: debugInstructionDecodeCount,
            decodedHostOutputs: debugHostOutputCount,
            decodedHostBytes: debugHostByteCount
        )
    }

    init(
        server: Server,
        reconnectionPolicy: ReconnectionPolicy = .mosh,
        makeUDPConnection: @escaping @MainActor (String, UInt16) -> any MoshUDPTransport = {
            MoshUDPConnection(host: $0, port: $1)
        }
    ) {
        self.server = server
        self.reconnectionPolicy = reconnectionPolicy
        self.makeUDPConnection = makeUDPConnection
    }

    // Full connection flow: SSH -> detect mosh-server -> start it -> UDP
    func connect(password: String? = nil, privateKeyTag: String? = nil) async {
        do {
            let status = try await prepareBootstrap(password: password, privateKeyTag: privateKeyTag)
            guard case .available = status else { return }
            try await startPreparedConnection()
        } catch {
            handleConnectionFailure(error)
        }
    }

    var bootstrapClient: SSHClient? {
        sshClient
    }

    func prepareBootstrap(
        password: String? = nil,
        privateKeyTag: String? = nil
    ) async throws -> MoshServerStatus {
        connectionState = .connecting
        untrustedHostIdentity = nil
        connectionError = nil

        do {
            connectionState = .sshBootstrap
            let client = try await SSHConnectionService.connect(
                server: server,
                password: password,
                privateKeyTag: privateKeyTag
            )
            try Task.checkCancellation()
            self.sshClient = client

            connectionState = .moshStarting
            let bootstrap = try makeBootstrapService(client: client)
            let status = try await bootstrap.detectMoshServer()
            try Task.checkCancellation()
            self.moshServerStatus = status

            switch status {
            case .available:
                break
            case .notFound(let packageManager):
                detectedPackageManager = packageManager
                connectionState = .error("mosh-server not found on remote host")
            case .notFoundNoPackageManager:
                connectionState = .error("mosh-server not found and no package manager detected")
            }
            return status
        } catch {
            handleConnectionFailure(error)
            throw error
        }
    }

    func startPreparedConnection(
        initialCommand: String? = nil,
        udpTimeout: TimeInterval = ConnectionTimeouts.default.udpConnection
    ) async throws {
        guard let client = sshClient else {
            throw ConnectionCoordinatorError.bootstrapUnavailable
        }

        do {
            connectionState = .moshStarting
            let bootstrap = try makeBootstrapService(client: client)
            let info = try await bootstrap.startMoshServer(
                initialCommand: initialCommand,
                replacingServerPID: replacingServerPID
            )
            replacingServerPID = nil
            try Task.checkCancellation()
            try await establishUDP(info: info, timeout: udpTimeout)
            try Task.checkCancellation()
            try? await client.close()
            sshClient = nil
        } catch {
            handleConnectionFailure(error)
            throw error
        }
    }

    func takeBootstrapClient() -> SSHClient? {
        let client = sshClient
        sshClient = nil
        return client
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

    func processInboundOutput(_ data: Data) async -> Data {
        let result = await agentEventDecoder.ingest(data)
        for event in result.events {
            onAgentEvent?(event)
        }
        return result.terminalOutput
    }

    // Called by ViewModel after user accepts install offer
    func installAndConnect(using packageManager: RemotePackageManager, password: String? = nil, privateKeyTag: String? = nil) async {
        do {
            try await installServer(
                using: packageManager,
                password: password,
                privateKeyTag: privateKeyTag
            )
            try await startPreparedConnection()
        } catch {
            handleConnectionFailure(error)
        }
    }

    func installServer(
        using packageManager: RemotePackageManager,
        password: String? = nil,
        privateKeyTag: String? = nil
    ) async throws {
        do {
            // Reuse existing SSH client or reconnect
            let client: SSHClient
            if let existing = sshClient {
                client = existing
            } else {
                connectionState = .sshBootstrap
                client = try await SSHConnectionService.connect(
                    server: server,
                    password: password,
                    privateKeyTag: privateKeyTag
                )
                self.sshClient = client
            }

            connectionState = .moshStarting
            let bootstrap = try makeBootstrapService(client: client)

            // Install mosh-server
            try await bootstrap.installMoshServer(using: packageManager)
            moshServerStatus = try await bootstrap.detectMoshServer()

        } catch {
            handleConnectionFailure(error)
            throw error
        }
    }

    /// Queues keystrokes for mosh-server. Input typed while the UDP path is being restored
    /// is kept and delivered once it is back, as mosh does.
    func send(_ data: Data) async {
        guard acceptsInput, !data.isEmpty else { return }
        if Self.inputTraceEnabled {
            let preview = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[INPUT_TRACE] moshQueue state=\(stateSync.sender.currentNum) bytes=\(data.count) preview=\(preview)")
        }
        stateSync.enqueue(MoshUserInput.encodeKeystroke(data))
        transmitSignal.fire()
    }

    /// Connected, or temporarily restoring the UDP path.
    private var acceptsInput: Bool {
        !sessionEndedNormally && (connectionState == .connected || connectionState == .reconnecting)
    }

    // Send a string
    func sendString(_ string: String) async {
        guard let data = string.data(using: .utf8) else { return }
        await send(data)
    }

    // Resize the remote terminal
    func resize(cols: Int, rows: Int) async {
        guard acceptsInput else {
            // Sent once the session connects.
            pendingTerminalSize = (cols, rows)
            return
        }
        pendingTerminalSize = nil
        stateSync.enqueue(MoshUserInput.encodeResize(width: Int32(cols), height: Int32(rows)))
        transmitSignal.fire()
    }

    // Called when the app returns to foreground to ensure UDP connectivity
    func handleAppResume() async {
        isAppActive = true
        guard connectionState == .connected || connectionState == .reconnecting else { return }
        requestRecovery(trigger: "app became active")
        await recoveryTask?.value
    }

    func handleAppBackground() {
        isAppActive = false
        pauseRecoveryBudget()
        recoveryTask?.cancel()
        recoveryTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transmitTask?.cancel()
        transmitTask = nil
        startupProbeTask?.cancel()
        startupProbeTask = nil
    }

    func retryRecovery() async {
        guard connectionState != .disconnected else { return }
        recoveryElapsed = 0
        recoveryStartedAt = nil
        connectionError = nil
        requestRecovery(trigger: "manual retry")
        await recoveryTask?.value
    }

    // Disconnect everything
    func disconnect() async {
        outputClosed = true
        await requestServerShutdown()
        isAppActive = false
        recoveryTask?.cancel()
        receiveTask?.cancel()
        transmitTask?.cancel()
        networkWatchTask?.cancel()
        startupProbeTask?.cancel()
        startupReadinessContinuation?.finish()
        receiveTask = nil
        transmitTask = nil
        networkWatchTask = nil
        startupProbeTask = nil
        startupReadinessContinuation = nil
        recoveryTask = nil
        recoveryElapsed = 0
        recoveryStartedAt = nil
        recoveryStatus = .idle

        udpConnection?.disconnect()
        udpConnection = nil

        try? await sshClient?.close()
        sshClient = nil

        networkMonitor.stop()
        protocolEngine = nil
        resetRoundTripTime()
        bufferedTerminalOutput.removeAll()
        consecutiveDatagramFailures = 0
        debugSendInstructionCount = 0
        debugSendDatagramCount = 0
        debugReceiveDatagramCount = 0
        debugDecryptSuccessCount = 0
        debugInstructionDecodeCount = 0
        debugHostOutputCount = 0
        debugHostByteCount = 0
        connectionState = .disconnected
    }

    // MARK: - Private

    // A UDP socket being locally ready does not prove that a remote mosh-server can respond.
    func establishUDP(info: MoshConnectionInfo, timeout: TimeInterval) async throws {
        connectionState = .moshStarting

        // Set up crypto
        protocolEngine = try MoshProtocolEngine(key: info.sessionKey)
        resetRoundTripTime()

        // Create UDP connection
        let udp = makeUDPConnection(info.serverIP, info.udpPort)
        self.udpConnection = udp
        udpHost = info.serverIP
        udpPort = info.udpPort
        transportGeneration = UUID()
        sessionEndedNormally = false
        stateSync = MoshStateSync()
        serverPID = info.serverPID
        outputClosed = false
        consecutiveDatagramFailures = 0
        debugSendInstructionCount = 0
        debugSendDatagramCount = 0
        debugReceiveDatagramCount = 0
        debugDecryptSuccessCount = 0
        debugInstructionDecodeCount = 0
        debugHostOutputCount = 0
        debugHostByteCount = 0

        do {
            try await ConnectionDeadline.run(timeout: timeout, phase: .udpConnection) {
                try await udp.connect()
                try Task.checkCancellation()
                try await self.awaitAuthenticatedServerResponse()
            }
        } catch {
            let wasAwaitingServerResponse = udp.isReady
            discardPendingUDPStartup()

            if let timeoutError = error as? ConnectionCoordinatorError,
               case .timedOut(phase: .udpConnection, seconds: let seconds) = timeoutError,
               wasAwaitingServerResponse {
                throw MoshUDPError.noServerResponse(
                    host: info.serverIP,
                    port: info.udpPort,
                    seconds: seconds
                )
            }
            throw error
        }

        connectionState = .connected
        recoveryStatus = .idle
        recoveryElapsed = 0
        recoveryStartedAt = nil

        startTransmitter()
        let size = pendingTerminalSize ?? Self.initialTerminalSize
        await resize(cols: size.cols, rows: size.rows)

        // Start network monitoring for auto-reconnect
        startNetworkWatch()
    }

    private func awaitAuthenticatedServerResponse() async throws {
        let (responses, continuation) = AsyncStream<Void>.makeStream()
        startupReadinessContinuation = continuation

        defer {
            startupProbeTask?.cancel()
            startupProbeTask = nil
            startupReadinessContinuation?.finish()
            startupReadinessContinuation = nil
        }

        startReceiveLoop()
        try await sendStartupProbe()
        startStartupProbeRetries()

        for await _ in responses {
            try Task.checkCancellation()
            return
        }

        try Task.checkCancellation()
        throw MoshUDPError.connectionFailed("Mosh startup ended before the server responded")
    }

    private func sendStartupProbe() async throws {
        try await sendTransportInstruction(stateSync.acknowledgementInstruction())
    }

    private func startStartupProbeRetries() {
        startupProbeTask?.cancel()
        startupProbeTask = Task { [weak self] in
            let retryDelays: [Duration] = [
                .milliseconds(250),
                .milliseconds(500),
                .seconds(1),
                .seconds(2),
            ]
            var retry = 0

            while !Task.isCancelled {
                do {
                    let delay = retryDelays[min(retry, retryDelays.count - 1)]
                    try await Task.sleep(for: delay)
                    try Task.checkCancellation()
                    guard let self, self.startupReadinessContinuation != nil else { return }
                    try await self.sendStartupProbe()
                    retry += 1
                } catch is CancellationError {
                    return
                } catch {
                    self?.reportNonFatalError(error, context: "startup probe")
                    retry += 1
                }
            }
        }
    }

    private func discardPendingUDPStartup() {
        startupProbeTask?.cancel()
        startupProbeTask = nil
        startupReadinessContinuation?.finish()
        startupReadinessContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        udpConnection?.disconnect()
        udpConnection = nil
        protocolEngine = nil
    }

    // Continuously receive and process incoming datagrams from mosh-server
    private func startReceiveLoop() {
        guard let udpConnection else { return }
        let generation = transportGeneration

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let datagram = try await udpConnection.receive()
                    guard let self,
                          !Task.isCancelled,
                          self.transportGeneration == generation else { return }
                    await self.processDatagram(datagram)
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.transportGeneration == generation else { return }
                    self.reportNonFatalError(error, context: "receive datagram")
                    self.requestRecovery(trigger: "receive failure", underlyingError: error)
                    return
                }
            }
        }
    }

    private func recordRoundTripSample(_ sample: TimeInterval?) {
        guard let sample else { return }
        let smoothed = roundTripEstimator.record(sample)
        // Publish only meaningful moves so the header doesn't re-render per packet.
        if let current = roundTripTime, abs(current - smoothed) < 0.005 { return }
        roundTripTime = smoothed
    }

    private func resetRoundTripTime() {
        roundTripEstimator.reset()
        roundTripTime = nil
    }

    // Decrypt, reassemble, and decode a received datagram
    private func processDatagram(_ datagram: Data) async {
        guard let protocolEngine else { return }
        debugReceiveDatagramCount += 1

        do {
            guard let decoded = try await protocolEngine.decode(datagram) else {
                debugDecryptSuccessCount += 1
                return
            }
            debugDecryptSuccessCount += 1
            recordRoundTripSample(decoded.roundTripSample)
            stateSync.heardFromServer(at: CACurrentMediaTime())
            let instruction = decoded.instruction
            debugInstructionDecodeCount += 1
            let prevRemote = stateSync.remoteStateNum
            let receipt = stateSync.receive(instruction)
            // Ack right away so mosh-server sends its next diff from our state.
            transmitSignal.fire()

            startupReadinessContinuation?.yield(())
            startupReadinessContinuation?.finish()
            startupReadinessContinuation = nil

            if Self.sspTraceEnabled {
                sspLog.notice("[SSP] old=\(instruction.oldNum)→\(instruction.newNum) prevRemote=\(prevRemote) receipt=\(String(describing: receipt)) diffBytes=\(instruction.diff.count)")
            }

            if receipt == .applied, !instruction.diff.isEmpty {
                let outputs = decoded.outputs
                debugHostOutputCount += outputs.count
                for (idx, output) in outputs.enumerated() {
                    if let rawHostString = output.hostString {
                        let processed = await processInboundOutput(rawHostString)
                        guard !outputClosed else { return }
                        guard !processed.isEmpty else { continue }
                        let hostString = stateSync.terminalBytes(processed)
                        debugHostByteCount += hostString.count

                        if Self.sspTraceEnabled {
                            let hex = hostString.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                            sspLog.notice("[SSP]   output[\(idx)] \(hostString.count)B hex=\(hex, privacy: .public)")
                        }

                        if let callback = onDataReceived {
                            callback(Array(hostString))
                        } else {
                            bufferTerminalOutput(hostString)
                        }
                    } else if Self.sspTraceEnabled {
                        sspLog.notice("[SSP]   output[\(idx)] nil hostString (echoAck=\(output.echoAck ?? -1))")
                    }
                }
            }
            consecutiveDatagramFailures = 0

            // Only a shutdown state we actually applied counts, so its final output was shown.
            if stateSync.remoteEnded {
                await finishRemoteShutdown()
            }
        } catch MoshProtocolError.unauthenticated {
            // Not from our mosh-server (or corrupted). Anyone who can reach the port can
            // send these, so they must never affect the session.
            debugUnauthenticatedDatagramCount += 1
        } catch {
            consecutiveDatagramFailures += 1
            reportNonFatalError(error, context: "process datagram")
            if consecutiveDatagramFailures >= 5 {
                connectionError = error
                connectionState = .error(ErrorPresentation.classify(
                    error,
                    context: .connection(server: server)
                ).explanation)
            }
        }
    }

    /// The remote shell exited. Acknowledge the shutdown state so mosh-server exits
    /// right away instead of waiting out its timeout, then end like an SSH `exit`.
    private func finishRemoteShutdown() async {
        guard !sessionEndedNormally else { return }
        sessionEndedNormally = true
        recoveryLog.notice("Mosh server reported that the remote shell exited")

        let instruction = stateSync.acknowledgementInstruction()
        // UDP may drop one; mosh-server retransmits its shutdown until acked anyway.
        for _ in 0..<2 {
            do {
                try await sendTransportInstruction(instruction)
            } catch {
                reportNonFatalError(error, context: "shutdown ack")
                break
            }
        }

        await disconnect()
    }

    /// Asks mosh-server to exit when the user closes a live session; otherwise it would
    /// keep the shell running forever. Waits briefly for the acknowledgement.
    private func requestServerShutdown() async {
        guard !sessionEndedNormally,
              connectionState == .connected,
              recoveryStatus == .idle,
              receiveTask != nil,
              udpConnection?.isReady == true else { return }

        transmitTask?.cancel()
        transmitTask = nil
        let instruction = stateSync.shutdownInstruction()
        for _ in 0..<3 {
            do {
                try await sendTransportInstruction(instruction)
            } catch {
                reportNonFatalError(error, context: "client shutdown")
                return
            }
            let deadline = CACurrentMediaTime() + 0.15
            while !stateSync.clientShutdownAcknowledged, CACurrentMediaTime() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if stateSync.clientShutdownAcknowledged { return }
        }
    }

    private var retransmitTimeout: TimeInterval {
        MoshStateSync.retransmitTimeout(smoothedRoundTrip: roundTripEstimator.smoothed)
    }

    /// Sends new input, resends unacknowledged input, and keeps the path alive. Woken by
    /// input and by received diffs that need a quick ack; otherwise sleeps until the next
    /// resend or heartbeat is due.
    private func startTransmitter() {
        transmitTask?.cancel()
        let generation = transportGeneration
        stateSync.resetHeartbeat(now: CACurrentMediaTime())
        transmitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.transportGeneration == generation,
                      self.connectionState == .connected,
                      self.recoveryStatus == .idle else { return }

                if self.stateSync.serverIsSilent(now: CACurrentMediaTime()) {
                    self.requestRecovery(trigger: "server silent")
                    return
                }

                let timeout = self.retransmitTimeout
                do {
                    try await self.transmitDueInstruction(timeout: timeout)
                } catch {
                    guard !Task.isCancelled, self.transportGeneration == generation else { return }
                    self.reportNonFatalError(error, context: "transmit")
                    self.requestRecovery(trigger: "transmit failure", underlyingError: error)
                    return
                }

                let wake = self.stateSync.nextTransmissionDue(timeout: timeout)
                await self.transmitSignal.wait(timeout: max(0.005, wake - CACurrentMediaTime()))
            }
        }
    }

    private func transmitDueInstruction(timeout: TimeInterval) async throws {
        guard let instruction = stateSync.nextTransmission(now: CACurrentMediaTime(), timeout: timeout) else { return }
        if Self.inputTraceEnabled, !instruction.diff.isEmpty {
            print("[INPUT_TRACE] moshSend state=\(instruction.oldNum)→\(instruction.newNum) ack=\(instruction.ackNum) diffLen=\(instruction.diff.count)")
        }
        try await sendTransportInstruction(instruction)
    }

    // Watch for network changes and trigger UDP reconnection
    private func startNetworkWatch() {
        networkMonitor.start()

        networkWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { break }

                if self.networkMonitor.didChangeNetwork {
                    self.networkMonitor.acknowledgeNetworkChange()
                    self.requestRecovery(trigger: "network path changed")
                }
            }
        }
    }

    private func requestRecovery(trigger: String, underlyingError: Error? = nil) {
        guard isAppActive,
              !sessionEndedNormally,
              connectionState != .disconnected,
              recoveryTask == nil else { return }

        if let underlyingError {
            connectionError = underlyingError
        }
        recoveryLog.notice("Mosh recovery requested: \(trigger, privacy: .public)")
        connectionState = .reconnecting
        recoveryStatus = networkMonitor.isConnected ? .reconnecting : .waitingForNetwork
        recoveryStartedAt = Date()

        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.runRecoveryLoop()
            if !Task.isCancelled {
                self.recoveryTask = nil
            }
        }
    }

    private func runRecoveryLoop() async {
        transportGeneration = UUID()
        receiveTask?.cancel()
        transmitTask?.cancel()
        startupProbeTask?.cancel()
        startupReadinessContinuation?.finish()
        receiveTask = nil
        transmitTask = nil
        startupProbeTask = nil
        startupReadinessContinuation = nil
        udpConnection?.disconnect()
        udpConnection = nil
        await protocolEngine?.discardIncompleteFragments()

        var attempt = 0
        var lastError: Error = MoshSessionError.udpNotReady

        while isAppActive, !Task.isCancelled, remainingRecoveryBudget > 0 {
            if !networkMonitor.isConnected {
                recoveryStatus = .waitingForNetwork
                do {
                    try await Task.sleep(for: .seconds(min(1, remainingRecoveryBudget)))
                } catch {
                    pauseRecoveryBudget()
                    return
                }
                continue
            }

            recoveryStatus = .reconnecting
            attempt += 1
            recoveryLog.notice("Mosh recovery attempt \(attempt, privacy: .public)")

            do {
                try await attemptMoshRecovery(timeout: min(reconnectionPolicy.attemptTimeout, remainingRecoveryBudget))
                guard !Task.isCancelled, isAppActive else { return }
                recoveryElapsed = 0
                recoveryStartedAt = nil
                connectionError = nil
                recoveryStatus = .idle
                connectionState = .connected
                // Whatever was in flight on the old socket may be gone.
                stateSync.resendUnacknowledgedInput()
                startTransmitter()
                recoveryLog.notice("Mosh recovery authenticated successfully")
                return
            } catch is CancellationError {
                pauseRecoveryBudget()
                return
            } catch {
                lastError = error
                connectionError = error
                reportNonFatalError(error, context: "recovery attempt \(attempt)")
            }

            let delay = min(reconnectionPolicy.delay(forAttempt: attempt), remainingRecoveryBudget)
            guard delay > 0 else { break }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                pauseRecoveryBudget()
                return
            }
        }

        pauseRecoveryBudget()
        guard isAppActive, !Task.isCancelled else { return }
        let message = "Mosh hasn't heard from the server in 60 seconds. The session may have ended on the server, or the network is blocking UDP."
        recoveryStatus = .unavailable(message)
        connectionError = lastError
        connectionState = .error(message)
        recoveryLog.error("Mosh recovery budget exhausted")
    }

    private func attemptMoshRecovery(timeout: TimeInterval) async throws {
        guard timeout > 0,
              let udpHost,
              let udpPort,
              protocolEngine != nil else {
            throw MoshSessionError.udpNotReady
        }

        receiveTask?.cancel()
        startupProbeTask?.cancel()
        startupReadinessContinuation?.finish()
        udpConnection?.disconnect()

        let generation = UUID()
        transportGeneration = generation
        let udp = makeUDPConnection(udpHost, udpPort)
        udpConnection = udp

        do {
            try await ConnectionDeadline.run(timeout: timeout, phase: .udpConnection) {
                try await udp.connect()
                try Task.checkCancellation()
                guard self.transportGeneration == generation else { throw CancellationError() }
                try await self.awaitAuthenticatedServerResponse()
            }
        } catch {
            if transportGeneration == generation {
                receiveTask?.cancel()
                startupProbeTask?.cancel()
                startupReadinessContinuation?.finish()
                startupReadinessContinuation = nil
                udp.disconnect()
                udpConnection = nil
            }
            throw error
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

    private func sendTransportInstruction(_ instruction: MoshTransportInstruction) async throws {
        guard let protocolEngine, let udpConnection, udpConnection.isReady else {
            throw MoshSessionError.udpNotReady
        }

        let datagrams = try await protocolEngine.encode(instruction)
        debugSendInstructionCount += 1

        for datagram in datagrams {
            try Task.checkCancellation()
            try await udpConnection.send(datagram)
            debugSendDatagramCount += 1
        }
    }

    private func reportNonFatalError(_ error: Error, context: String) {
        print("[MoshSession] \(context): \(ErrorRedactor.redact(error.localizedDescription))")
    }

    private func makeBootstrapService(client: SSHClient) throws -> MoshBootstrapService {
        let portRange: MoshPortRange?
        if let rawRange = server.moshUDPPortRange,
           !rawRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = MoshPortRange(rawRange) else {
                throw ConnectionCoordinatorError.invalidMoshPortRange(rawRange)
            }
            portRange = parsed
        } else {
            portRange = nil
        }

        return MoshBootstrapService(
            client: client,
            hostname: server.hostname,
            configuredServerPath: server.moshServerPath,
            portRange: portRange
        )
    }

    private func handleConnectionFailure(_ error: Error) {
        if error is CancellationError {
            connectionState = .disconnected
            return
        }

        if let hostKeyError = error as? SSHHostKeyTrustError,
           case .untrusted(let identity) = hostKeyError {
            untrustedHostIdentity = identity
        }
        connectionError = error
        connectionState = .error(ErrorPresentation.classify(
            error,
            context: .connection(server: server)
        ).explanation)
    }
}

// Conform to TerminalSession protocol
extension MoshSession: TerminalSession {}

enum MoshSessionError: LocalizedError {
    case udpNotReady
    case packetTooShort(Int)
    case compressionFailed(Int)
    case decompressionFailed(Int)
    case decompressionOverflow

    var errorDescription: String? {
        switch self {
        case .udpNotReady:
            return "Mosh UDP link is not ready"
        case .packetTooShort(let length):
            return "Mosh packet too short (\(length) bytes)"
        case .compressionFailed(let status):
            return "Failed to compress mosh instruction (zlib status \(status))"
        case .decompressionFailed(let status):
            return "Failed to decompress mosh instruction (zlib status \(status))"
        case .decompressionOverflow:
            return "Decompressed mosh instruction exceeded maximum buffer size"
        }
    }
}

/// Wakes the transmit loop early. A fire with nobody waiting is remembered once.
@MainActor
private final class MoshTransmitSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending = false
    private var timer: Task<Void, Never>?

    func fire() {
        if let continuation {
            self.continuation = nil
            timer?.cancel()
            timer = nil
            continuation.resume()
        } else {
            pending = true
        }
    }

    /// Returns when fired or after `timeout`, whichever is first, or when the task is cancelled.
    func wait(timeout: TimeInterval) async {
        if pending {
            pending = false
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.timeOut()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.timeOut() }
        }
    }

    private func timeOut() {
        guard let continuation else { return }
        self.continuation = nil
        timer = nil
        continuation.resume()
    }
}
