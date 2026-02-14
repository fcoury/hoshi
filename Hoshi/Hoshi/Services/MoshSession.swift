import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
import Network
import zlib
import os.log
import QuartzCore
@preconcurrency import CCryptoBoringSSL

private let sspLog = Logger(subsystem: "com.hoshi.app.dev", category: "SSP")

// Full mosh session: SSH bootstrap -> mosh-server detection/launch -> UDP communication
@MainActor
final class MoshSession: ObservableObject {
    private static let inputTraceEnabled = ProcessInfo.processInfo.environment["HOSHI_INPUT_TRACE"] == "1"
    private static let sspTraceEnabled = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var outputBuffer: String = ""

    // Mosh-specific state exposed to ViewModel for UI decisions
    @Published var moshServerStatus: MoshServerStatus?
    @Published var detectedPackageManager: RemotePackageManager?

    let server: Server

    // Raw data callback for feeding bytes directly to the terminal renderer
    var onDataReceived: TerminalDataCallback?

    private var sshClient: SSHClient?
    private var udpConnection: MoshUDPConnection?
    private var cryptoSession: MoshCryptoSession?
    private var fragmentAssembly = MoshFragmentAssembly()
    private var fragmenter = MoshFragmenter()
    private var networkMonitor = NetworkMonitorService()

    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var networkWatchTask: Task<Void, Never>?
    private var isReconnecting = false

    // SSP state tracking
    private var sendSequenceNumber: UInt64 = 0
    private var localStateNum: UInt64 = 0
    private var remoteStateNum: UInt64 = 0
    private var lastRemoteTimestamp: UInt16 = 0
    private var consecutiveDatagramFailures = 0
    // When we skip diffs due to base mismatch, we send an immediate
    // ack so the server retransmits from our actual state quickly
    // (~100ms RTT) instead of waiting for the 3s heartbeat cycle.
    private var needsImmediateAck = false

    // Track time of last received datagram for session-end detection.
    // If no data arrives for 15s while connected, the remote session
    // has likely ended (user typed 'exit').
    private var lastReceiveTime: CFTimeInterval = CACurrentMediaTime()

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

    init(server: Server) {
        self.server = server
    }

    // Full connection flow: SSH -> detect mosh-server -> start it -> UDP
    func connect(password: String? = nil, privateKeyTag: String? = nil) async {
        connectionState = .connecting

        do {
            // Step 1: SSH connect
            connectionState = .sshBootstrap
            let client = try await sshConnect(password: password, privateKeyTag: privateKeyTag)
            self.sshClient = client

            // Step 2: Detect mosh-server
            connectionState = .moshStarting
            let bootstrap = MoshBootstrapService(client: client, hostname: server.hostname)
            let status = try await bootstrap.detectMoshServer()
            self.moshServerStatus = status

            switch status {
            case .available:
                // mosh-server found — start it
                let info = try await bootstrap.startMoshServer()
                // Close SSH connection (mosh-server is detached)
                try? await client.close()
                self.sshClient = nil
                // Establish UDP
                try await establishUDP(info: info)

            case .notFound(let pm):
                self.detectedPackageManager = pm
                // Signal to ViewModel that install offer is needed
                connectionState = .error("mosh-server not found on remote host")
                return

            case .notFoundNoPackageManager:
                connectionState = .error("mosh-server not found and no package manager detected")
                return
            }

        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }

    // Called by ViewModel after user accepts install offer
    func installAndConnect(using packageManager: RemotePackageManager, password: String? = nil, privateKeyTag: String? = nil) async {
        do {
            // Reuse existing SSH client or reconnect
            let client: SSHClient
            if let existing = sshClient {
                client = existing
            } else {
                connectionState = .sshBootstrap
                client = try await sshConnect(password: password, privateKeyTag: privateKeyTag)
                self.sshClient = client
            }

            connectionState = .moshStarting
            let bootstrap = MoshBootstrapService(client: client, hostname: server.hostname)

            // Install mosh-server
            try await bootstrap.installMoshServer(using: packageManager)

            // Start mosh-server
            let info = try await bootstrap.startMoshServer()

            // Close SSH
            try? await client.close()
            self.sshClient = nil

            // Establish UDP
            try await establishUDP(info: info)

        } catch {
            connectionState = .error(error.localizedDescription)
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
        receiveTask = nil
        heartbeatTask = nil
        networkWatchTask = nil

        udpConnection?.disconnect()
        udpConnection = nil

        try? await sshClient?.close()
        sshClient = nil

        networkMonitor.stop()
        cryptoSession = nil
        lastRemoteTimestamp = 0
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

    // SSH connect reusing the same auth logic as SSHSession
    private func sshConnect(password: String?, privateKeyTag: String?) async throws -> SSHClient {
        let authMethod = try buildAuthMethod(
            server: server,
            password: password,
            privateKeyTag: privateKeyTag
        )

        return try await SSHClient.connect(
            host: server.hostname,
            port: server.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }

    // Establish UDP connection and start receive loop
    private func establishUDP(info: MoshConnectionInfo) async throws {
        // Set up crypto
        cryptoSession = try MoshCryptoSession(key: info.sessionKey)

        // Create UDP connection
        let udp = MoshUDPConnection(host: info.serverIP, port: info.udpPort)
        self.udpConnection = udp
        sendSequenceNumber = 0
        localStateNum = 0
        remoteStateNum = 0
        needsImmediateAck = false
        mouseTrackingActive = false
        lastReceiveTime = CACurrentMediaTime()
        lastRemoteTimestamp = 0
        consecutiveDatagramFailures = 0
        fragmentAssembly.reset()
        debugSendInstructionCount = 0
        debugSendDatagramCount = 0
        debugReceiveDatagramCount = 0
        debugDecryptSuccessCount = 0
        debugInstructionDecodeCount = 0
        debugHostOutputCount = 0
        debugHostByteCount = 0

        // Connect and wait for ready state
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
                    continuation.resume(throwing: MoshUDPError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
        }

        connectionState = .connected

        // Start receiving datagrams
        startReceiveLoop()

        // Start heartbeat to maintain NAT mapping
        startHeartbeat()

        // Start network monitoring for auto-reconnect
        startNetworkWatch()
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
        guard let cryptoSession else { return }
        lastReceiveTime = CACurrentMediaTime()
        debugReceiveDatagramCount += 1

        do {
            // Decrypt
            let (plaintext, _) = try cryptoSession.decrypt(
                datagram: datagram,
                direction: .toClient
            )
            debugDecryptSuccessCount += 1
            let packetPayload = try depacketize(plaintext)

            // Parse transport fragment
            let fragment = try MoshFragment(fromPayload: packetPayload)

            // Reassemble (most messages are single-fragment)
            guard let completeInstruction = fragmentAssembly.addFragment(fragment) else {
                return // Waiting for more fragments
            }

            // Transport instruction payload is zlib-compressed.
            let instructionBytes = try decompressInstruction(completeInstruction)
            let instruction = try MoshTransportInstruction.decode(from: instructionBytes)
            debugInstructionDecodeCount += 1

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
                    let outputs = try MoshHostOutput.decode(from: instruction.diff)
                    debugHostOutputCount += outputs.count
                    for (idx, output) in outputs.enumerated() {
                        if let hostString = output.hostString {
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
                            } else if let text = String(data: hostString, encoding: .utf8) {
                                outputBuffer.append(text)
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
                connectionState = .error("Mosh protocol error: \(error.localizedDescription)")
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

                // Detect dead session: if no datagrams received for 15s
                // while connected, the remote mosh-server has likely exited.
                let timeSinceLastReceive = CACurrentMediaTime() - self.lastReceiveTime
                if timeSinceLastReceive > 15.0 && self.connectionState == .connected {
                    self.connectionState = .disconnected
                    return
                }

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

        let previousState = connectionState
        connectionState = .reconnecting

        // Cancel the receive loop and discard stale partial fragments
        receiveTask?.cancel()
        fragmentAssembly.reset()

        // Reconnect the UDP socket (new local port, same remote endpoint)
        udpConnection?.reconnect()

        // Brief wait for connection to establish
        try? await Task.sleep(for: .milliseconds(500))

        if udpConnection?.isReady == true {
            connectionState = .connected
            startReceiveLoop()
        } else {
            connectionState = previousState
        }
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
        guard let cryptoSession, let udpConnection, udpConnection.isReady else {
            throw MoshSessionError.udpNotReady
        }

        let encoded = instruction.encode()
        let compressed = try compressInstruction(encoded)
        let fragments = fragmenter.fragment(compressed)
        debugSendInstructionCount += 1

        for fragment in fragments {
            let fragmentData = fragment.toData()
            let packet = packetize(fragmentData)
            sendSequenceNumber += 1
            let nonce = MoshNonce(direction: .toServer, sequenceNumber: sendSequenceNumber)
            let datagram = try cryptoSession.encrypt(plaintext: packet, nonce: nonce)
            try await udpConnection.send(datagram)
            debugSendDatagramCount += 1
        }
    }

    private func packetize(_ payload: Data) -> Data {
        var packet = Data(capacity: 4 + payload.count)
        let timestamp = currentTimestamp()
        packet.append(UInt8((timestamp >> 8) & 0xFF))
        packet.append(UInt8(timestamp & 0xFF))
        packet.append(UInt8((lastRemoteTimestamp >> 8) & 0xFF))
        packet.append(UInt8(lastRemoteTimestamp & 0xFF))
        packet.append(payload)
        return packet
    }

    private func depacketize(_ packet: Data) throws -> Data {
        guard packet.count >= 4 else {
            throw MoshSessionError.packetTooShort(packet.count)
        }

        let remoteTimestamp = (UInt16(packet[0]) << 8) | UInt16(packet[1])
        lastRemoteTimestamp = remoteTimestamp
        return Data(packet.dropFirst(4))
    }

    private func currentTimestamp() -> UInt16 {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        return UInt16(truncatingIfNeeded: millis)
    }

    private func reportNonFatalError(_ error: Error, context: String) {
        print("[MoshSession] \(context): \(error.localizedDescription)")
    }

    private func compressInstruction(_ instruction: Data) throws -> Data {
        var destinationLength = compressBound(uLong(instruction.count))
        var destination = Data(count: Int(destinationLength))

        let status = destination.withUnsafeMutableBytes { destinationBuffer in
            instruction.withUnsafeBytes { sourceBuffer in
                compress(
                    destinationBuffer.bindMemory(to: Bytef.self).baseAddress,
                    &destinationLength,
                    sourceBuffer.bindMemory(to: Bytef.self).baseAddress,
                    uLong(instruction.count)
                )
            }
        }

        guard status == Z_OK else {
            throw MoshSessionError.compressionFailed(Int(status))
        }

        destination.removeSubrange(Int(destinationLength)..<destination.count)
        return destination
    }

    private func decompressInstruction(_ compressedInstruction: Data) throws -> Data {
        // Upstream mosh caps this at 2048 * 2048.
        let maxBufferSize = 4 * 1024 * 1024
        var bufferSize = max(1024, compressedInstruction.count * 8)

        while bufferSize <= maxBufferSize {
            var destinationLength = uLong(bufferSize)
            var destination = Data(count: bufferSize)

            let status = destination.withUnsafeMutableBytes { destinationBuffer in
                compressedInstruction.withUnsafeBytes { sourceBuffer in
                    uncompress(
                        destinationBuffer.bindMemory(to: Bytef.self).baseAddress,
                        &destinationLength,
                        sourceBuffer.bindMemory(to: Bytef.self).baseAddress,
                        uLong(compressedInstruction.count)
                    )
                }
            }

            if status == Z_OK {
                destination.removeSubrange(Int(destinationLength)..<destination.count)
                return destination
            }

            if status == Z_BUF_ERROR {
                bufferSize *= 2
                continue
            }

            throw MoshSessionError.decompressionFailed(Int(status))
        }

        throw MoshSessionError.decompressionOverflow
    }

    // Build SSH auth method (duplicated from SSHSession to avoid tight coupling)
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

            // Ed25519 (32 bytes)
            if keyData.count == 32 {
                let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
                return .ed25519(username: server.username, privateKey: privateKey)
            }

            // RSA (PKCS#1 DER)
            let components = try SSHKeyService.parseRSAPrivateKeyDER(keyData)
            let modulus = CCryptoBoringSSL_BN_bin2bn(components.n, components.n.count, nil)!
            let publicExponent = CCryptoBoringSSL_BN_bin2bn(components.e, components.e.count, nil)!
            let privateExponent = CCryptoBoringSSL_BN_bin2bn(components.d, components.d.count, nil)!

            let rsaKey = Insecure.RSA.PrivateKey(
                privateExponent: privateExponent,
                publicExponent: publicExponent,
                modulus: modulus
            )
            return .rsa(username: server.username, privateKey: rsaKey)
        }
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
