import Foundation
import Citadel
import NIOCore
import Network
import os.log
import QuartzCore

private let sspLog = Logger(subsystem: "com.hoshi.app.dev", category: "SSP")

// Full mosh session: SSH bootstrap -> mosh-server detection/launch -> UDP communication
@MainActor
final class MoshSession: ObservableObject {
    private static let inputTraceEnabled = ProcessInfo.processInfo.environment["HOSHI_INPUT_TRACE"] == "1"
    private static let sspTraceEnabled = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var outputBuffer: String = ""
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
    private var heartbeatTask: Task<Void, Never>?
    private var networkWatchTask: Task<Void, Never>?
    private var startupProbeTask: Task<Void, Never>?
    private var startupReadinessContinuation: AsyncStream<Void>.Continuation?
    private var isReconnecting = false

    // SSP state tracking
    private var localStateNum: UInt64 = 0
    private var remoteStateNum: UInt64 = 0
    private var consecutiveDatagramFailures = 0
    // When we skip diffs due to base mismatch, we send an immediate
    // ack so the server retransmits from our actual state quickly
    // (~100ms RTT) instead of waiting for the 3s heartbeat cycle.
    private var needsImmediateAck = false

    // Track whether a full-screen app (nvim, etc.) has enabled mouse
    // tracking. When it disables tracking on exit, we inject a screen
    // clear because the mosh server's terminal emulator handles the
    // alternate-screen switch internally (\x1b[?1049h/l) and never
    // sends those sequences to us.
    private var mouseTrackingActive = false
    private var debugSendInstructionCount = 0
    private var debugSendDatagramCount = 0
    private var debugReceiveDatagramCount = 0
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
            let info = try await bootstrap.startMoshServer(initialCommand: initialCommand)
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

    // Send keystrokes via the SSP protocol over UDP
    func send(_ data: Data) async {
        do {
            // Encode as user input protobuf
            let userInput = MoshUserInput.encodeKeystroke(data)

            // Wrap in a transport instruction
            var instruction = MoshTransportInstruction()
            instruction.oldNum = localStateNum
            localStateNum += 1
            instruction.newNum = localStateNum
            instruction.ackNum = remoteStateNum
            instruction.diff = userInput

            if Self.inputTraceEnabled {
                let preview = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[INPUT_TRACE] moshSend state=\(instruction.oldNum)→\(instruction.newNum) ack=\(instruction.ackNum) diffLen=\(userInput.count) preview=\(preview)")
            }

            try await sendTransportInstruction(instruction)
        } catch {
            reportNonFatalError(error, context: "send keystroke")
        }
    }

    // Send a string
    func sendString(_ string: String) async {
        guard let data = string.data(using: .utf8) else { return }
        await send(data)
    }

    // Resize the remote terminal
    func resize(cols: Int, rows: Int) async {
        do {
            let userInput = MoshUserInput.encodeResize(width: Int32(cols), height: Int32(rows))
            var instruction = MoshTransportInstruction()
            instruction.oldNum = localStateNum
            localStateNum += 1
            instruction.newNum = localStateNum
            instruction.ackNum = remoteStateNum
            instruction.diff = userInput
            try await sendTransportInstruction(instruction)
        } catch {
            reportNonFatalError(error, context: "send resize")
        }
    }

    // Called when the app returns to foreground to ensure UDP connectivity
    func handleAppResume() async {
        guard connectionState == .connected || connectionState == .reconnecting else { return }

        // Force a UDP reconnect to re-establish the path after potential iOS suspension
        await handleNetworkChange()
    }

    // Disconnect everything
    func disconnect() async {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        networkWatchTask?.cancel()
        startupProbeTask?.cancel()
        startupReadinessContinuation?.finish()
        receiveTask = nil
        heartbeatTask = nil
        networkWatchTask = nil
        startupProbeTask = nil
        startupReadinessContinuation = nil

        udpConnection?.disconnect()
        udpConnection = nil

        try? await sshClient?.close()
        sshClient = nil

        networkMonitor.stop()
        protocolEngine = nil
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

        // Create UDP connection
        let udp = makeUDPConnection(info.serverIP, info.udpPort)
        self.udpConnection = udp
        localStateNum = 0
        remoteStateNum = 0
        needsImmediateAck = false
        mouseTrackingActive = false
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
                try await self.waitForUDPSocketReady(udp)
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

        // Start heartbeat to maintain NAT mapping
        startHeartbeat()

        // Start network monitoring for auto-reconnect
        startNetworkWatch()
    }

    private func waitForUDPSocketReady(_ udp: any MoshUDPTransport) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                udp.connect { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume()
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        resumed = true
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                udp.disconnect()
            }
        }
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
        var instruction = MoshTransportInstruction()
        instruction.oldNum = localStateNum
        instruction.newNum = localStateNum
        instruction.ackNum = remoteStateNum
        try await sendTransportInstruction(instruction)
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

        receiveTask = Task { [weak self] in
            for await datagram in udpConnection.receiveStream() {
                guard let self, !Task.isCancelled else { break }
                await self.processDatagram(datagram)
            }
        }
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
            let instruction = decoded.instruction
            debugInstructionDecodeCount += 1

            startupReadinessContinuation?.yield(())
            startupReadinessContinuation?.finish()
            startupReadinessContinuation = nil

            // SSP overlap guard with exact-base matching.
            //
            // Only deliver diffs whose oldNum matches our current
            // remoteStateNum exactly. This safely skips:
            //  - Overlapping diffs (oldNum < remoteStateNum)
            //  - Gap diffs (oldNum > remoteStateNum from an intermediate
            //    base we never reached)
            //  - Stale diffs (newNum <= remoteStateNum)
            //
            // When we skip, we flag needsImmediateAck so the heartbeat
            // loop sends our acked state right away (~100ms RTT) instead
            // of waiting for the normal 3-second heartbeat cycle.
            let prevRemote = remoteStateNum
            let isNewRemoteState = instruction.newNum > remoteStateNum
            let isExactBase = instruction.oldNum == prevRemote

            if Self.sspTraceEnabled {
                sspLog.notice("[SSP] old=\(instruction.oldNum)→\(instruction.newNum) prevRemote=\(prevRemote) new=\(isNewRemoteState) exact=\(isExactBase) diffBytes=\(instruction.diff.count)")
            }

            if isNewRemoteState, isExactBase {
                // Base matches our state exactly — deliver all bytes.
                remoteStateNum = instruction.newNum
                // Tell the server our new state immediately so it can
                // send the next diff from the correct base without
                // waiting for the 3-second heartbeat.
                needsImmediateAck = true

                if !instruction.diff.isEmpty {
                    let outputs = decoded.outputs
                    debugHostOutputCount += outputs.count
                    for (idx, output) in outputs.enumerated() {
                        if let rawHostString = output.hostString {
                            let hostString = await processInboundOutput(rawHostString)
                            guard !hostString.isEmpty else { continue }
                            debugHostByteCount += hostString.count

                            // Mosh's server-side terminal emulator consumes
                            // alternate screen sequences (\x1b[?1049h/l)
                            // internally, so the diff may not fully clear
                            // Ghostty's display on screen transitions.
                            // Detect full-screen repaints (many erase-to-EOL
                            // sequences) and prepend a screen clear.
                            let needsClear = isFullScreenRepaint(hostString)

                            if Self.sspTraceEnabled {
                                let hex = hostString.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                                sspLog.notice("[SSP]   output[\(idx)] \(hostString.count)B clear=\(needsClear) hex=\(hex, privacy: .public)")
                            }

                            if let callback = onDataReceived {
                                if needsClear {
                                    // Prepend cursor-home + erase-display so
                                    // the full repaint starts on a clean screen.
                                    var buf = Data(capacity: 7 + hostString.count)
                                    buf.append(contentsOf: [0x1b, 0x5b, 0x48,        // \x1b[H  (cursor home)
                                                            0x1b, 0x5b, 0x32, 0x4a]) // \x1b[2J (erase display)
                                    buf.append(hostString)
                                    callback(Array(buf))
                                } else {
                                    callback(Array(hostString))
                                }

                                // Detect full-screen app exit via mouse tracking
                                // + bracketed paste disable in the same output.
                                // Apps like nvim enable \x1b[?1002h on start and
                                // disable it on exit alongside \x1b[?2004l. We
                                // require BOTH to avoid false positives when nvim
                                // briefly toggles mouse mode (e.g. command entry).
                                let mouseEnable  = Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x32, 0x68])  // \x1b[?1002h
                                let mouseDisable = Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x32, 0x6c])  // \x1b[?1002l
                                let pasteDisable = Data([0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x30, 0x34, 0x6c])  // \x1b[?2004l

                                if hostString.range(of: mouseEnable) != nil {
                                    mouseTrackingActive = true
                                }
                                let hasMouseOff = hostString.range(of: mouseDisable) != nil
                                let hasPasteOff = hostString.range(of: pasteDisable) != nil
                                if hasMouseOff, hasPasteOff, mouseTrackingActive {
                                    mouseTrackingActive = false
                                    callback([0x1b, 0x5b, 0x48,        // \x1b[H  (cursor home)
                                              0x1b, 0x5b, 0x32, 0x4a]) // \x1b[2J (erase display)
                                    if Self.sspTraceEnabled {
                                        sspLog.notice("[SSP]   → INJECTED screen clear (app exit: mouse+paste disabled)")
                                    }
                                }
                            } else {
                                bufferTerminalOutput(hostString)
                            }
                        } else if Self.sspTraceEnabled {
                            sspLog.notice("[SSP]   output[\(idx)] nil hostString (echoAck=\(output.echoAck ?? -1))")
                        }
                    }
                    if Self.sspTraceEnabled {
                        sspLog.notice("[SSP]   → DELIVER \(outputs.count) outputs (new state \(self.remoteStateNum))")
                    }
                }
            } else if isNewRemoteState {
                // Base mismatch — skip and request immediate retransmit.
                needsImmediateAck = true
                if Self.sspTraceEnabled {
                    sspLog.notice("[SSP]   → SKIP base≠ oldNum=\(instruction.oldNum) prevRemote=\(prevRemote), ack queued")
                }
            } else {
                // Stale diff: server is retransmitting because it
                // doesn't know our current state yet. Ack immediately.
                needsImmediateAck = true
                if Self.sspTraceEnabled {
                    sspLog.notice("[SSP]   → SKIP stale newNum=\(instruction.newNum) <= remoteStateNum=\(self.remoteStateNum)")
                }
            }
            consecutiveDatagramFailures = 0
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

    // Send periodic keepalive datagrams to maintain NAT mapping.
    // Also polls for needsImmediateAck to fast-ack skipped diffs,
    // prompting the server to retransmit from our actual state
    // within ~100ms instead of waiting for the 3-second cycle.
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            var ticksSinceLastHeartbeat = 0
            let tickInterval = 50  // ms
            let heartbeatTicks = 3000 / tickInterval  // 60 ticks = 3s

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(tickInterval))
                guard let self, !Task.isCancelled else { break }
                ticksSinceLastHeartbeat += 1

                // Send ack when overdue or when the overlap guard
                // flagged a base-mismatch skip.
                let sendNow = self.needsImmediateAck
                    || ticksSinceLastHeartbeat >= heartbeatTicks

                guard sendNow else { continue }

                if self.needsImmediateAck {
                    self.needsImmediateAck = false
                    if Self.sspTraceEnabled {
                        sspLog.notice("[SSP] Sending immediate ack (remoteState=\(self.remoteStateNum))")
                    }
                }

                ticksSinceLastHeartbeat = 0
                var instruction = MoshTransportInstruction()
                instruction.oldNum = self.localStateNum
                instruction.newNum = self.localStateNum
                instruction.ackNum = self.remoteStateNum
                do {
                    try await self.sendTransportInstruction(instruction)
                } catch {
                    self.reportNonFatalError(error, context: "heartbeat")
                }
            }
        }
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
                    await self.handleNetworkChange()
                }
            }
        }
    }

    // Handle network change: reconnect UDP (mosh-server keeps session alive).
    // Guarded to prevent overlapping calls from scene activation + network change.
    private func handleNetworkChange() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        connectionState = .reconnecting

        // Cancel the receive loop and discard stale partial fragments
        receiveTask?.cancel()
        await protocolEngine?.discardIncompleteFragments()

        for attempt in 1...reconnectionPolicy.maximumAttempts {
            guard !Task.isCancelled else { return }

            if !networkMonitor.isConnected {
                do {
                    try await Task.sleep(for: .seconds(reconnectionPolicy.delay(forAttempt: attempt)))
                } catch {
                    return
                }
                continue
            }

            udpConnection?.reconnect()

            do {
                try await Task.sleep(for: .seconds(reconnectionPolicy.delay(forAttempt: attempt)))
                try Task.checkCancellation()
            } catch {
                return
            }

            if udpConnection?.isReady == true {
                connectionState = .connected
                startReceiveLoop()
                return
            }
        }

        connectionState = .error("Mosh could not restore its UDP connection. Check network access and retry.")
    }

    // Detect full-screen repaints by counting erase-to-end-of-line
    // (\x1b[K) sequences. Mosh's screen-diff algorithm emits \x1b[K
    // for each changed line to clear remnants. A high count (≥10)
    // signals a full-screen transition (entering/exiting nvim, etc.)
    // where we need to prepend a screen clear because the mosh server
    // handles alternate-screen switching internally.
    private func isFullScreenRepaint(_ data: Data) -> Bool {
        let target: [UInt8] = [0x1b, 0x5b, 0x4b]  // \x1b[K
        var count = 0
        var i = data.startIndex

        while i <= data.endIndex - 3 {
            if data[i] == target[0], data[i+1] == target[1], data[i+2] == target[2] {
                count += 1
                if count >= 10 { return true }
                i += 3
            } else {
                i += 1
            }
        }
        return false
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
