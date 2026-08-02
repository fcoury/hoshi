import GhosttyKit
import SwiftData
import UIKit
import XCTest
@testable import Hoshi

@MainActor
final class ConnectionCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "hoshi.phase-two.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAutomaticTransportPrefersMoshAndFallsBackToSSH() {
        XCTAssertEqual(ConnectionTransportPolicy.auto.candidateTransports, [.mosh, .ssh])
    }

    func testExplicitTransportPoliciesDoNotFallBack() {
        XCTAssertEqual(ConnectionTransportPolicy.mosh.candidateTransports, [.mosh])
        XCTAssertEqual(ConnectionTransportPolicy.ssh.candidateTransports, [.ssh])
    }

    func testLegacySSHProfileRemainsSSH() {
        let server = makeServer()

        XCTAssertEqual(server.transportPolicy, .ssh)
        XCTAssertEqual(server.tmuxPolicy, .alwaysAsk)
    }

    func testLegacyMoshAndNamedTmuxProfilePreserveBehavior() {
        let server = Server(
            name: "Legacy",
            hostname: "example.com",
            username: "user",
            useMosh: true,
            tmuxSession: "agents"
        )

        XCTAssertEqual(server.transportPolicy, .mosh)
        XCTAssertEqual(server.tmuxPolicy, .autoAttachLast)
    }

    func testExplicitConnectionPoliciesAndMoshSettingsPersist() throws {
        let container = try ModelContainer(
            for: Server.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let server = Server(
            name: "Persistent",
            hostname: "example.com",
            username: "user",
            tmuxSession: "agents",
            transportPolicy: .auto,
            tmuxPolicy: .rawShell,
            moshServerPath: "/usr/local/bin/mosh-server",
            moshUDPPortRange: "60001:60020"
        )
        context.insert(server)
        try context.save()

        let loaded = try XCTUnwrap(context.fetch(FetchDescriptor<Server>()).first)
        XCTAssertEqual(loaded.transportPolicy, .auto)
        XCTAssertEqual(loaded.tmuxPolicy, .rawShell)
        XCTAssertEqual(loaded.moshServerPath, "/usr/local/bin/mosh-server")
        XCTAssertEqual(loaded.moshUDPPortRange, "60001:60020")
        XCTAssertTrue(loaded.useMosh)
    }

    func testChangingTransportPolicyKeepsLegacyMoshFlagInSync() {
        let server = makeServer()

        server.transportPolicy = .auto
        XCTAssertTrue(server.useMosh)

        server.transportPolicy = .mosh
        XCTAssertTrue(server.useMosh)

        server.transportPolicy = .ssh
        XCTAssertFalse(server.useMosh)
    }

    func testMoshPortRangeAcceptsSinglePortsAndRanges() {
        XCTAssertEqual(MoshPortRange("60000")?.argument, "60000")
        XCTAssertEqual(MoshPortRange("60000:61000")?.argument, "60000:61000")
        XCTAssertEqual(MoshPortRange("60000-61000")?.argument, "60000:61000")
        XCTAssertEqual(MoshPortRange(" 60001:60002 ")?.lowerBound, 60001)
        XCTAssertEqual(MoshPortRange("65535")?.upperBound, 65535)
    }

    func testMoshPortRangeRejectsInvalidOrDescendingValues() {
        for value in ["", "0", "65536", "61000:60000", "60000:", ":60000", "x:y", "1:2:3"] {
            XCTAssertNil(MoshPortRange(value), "Unexpectedly accepted \(value)")
        }
    }

    func testSSHReconnectBackoffIsExponentialAndBounded() {
        XCTAssertEqual(ReconnectionPolicy.ssh.delay(forAttempt: 0), 0)
        XCTAssertEqual(ReconnectionPolicy.ssh.delay(forAttempt: 1), 1)
        XCTAssertEqual(ReconnectionPolicy.ssh.delay(forAttempt: 2), 2)
        XCTAssertEqual(ReconnectionPolicy.ssh.delay(forAttempt: 3), 4)
        XCTAssertEqual(ReconnectionPolicy.ssh.delay(forAttempt: 8), 15)
    }

    func testMoshReconnectBackoffIsExponentialAndBounded() {
        XCTAssertEqual(ReconnectionPolicy.mosh.delay(forAttempt: 1), 0.25)
        XCTAssertEqual(ReconnectionPolicy.mosh.delay(forAttempt: 2), 0.5)
        XCTAssertEqual(ReconnectionPolicy.mosh.delay(forAttempt: 3), 1)
        XCTAssertEqual(ReconnectionPolicy.mosh.delay(forAttempt: 10), 15)
    }

    func testConnectionDeadlineReturnsSuccessfulOperation() async throws {
        let value = try await ConnectionDeadline.run(timeout: 1, phase: .sshBootstrap) {
            "connected"
        }

        XCTAssertEqual(value, "connected")
    }

    func testConnectionDeadlineFailsAndRunsCleanup() async {
        var cleanedUp = false

        do {
            _ = try await ConnectionDeadline.run(
                timeout: 0.02,
                phase: .udpConnection,
                onTimeout: { cleanedUp = true }
            ) {
                try await Task.sleep(for: .seconds(1))
                return "late"
            }
            XCTFail("Expected the UDP deadline to expire")
        } catch let error as ConnectionCoordinatorError {
            XCTAssertEqual(error, .timedOut(phase: .udpConnection, seconds: 0.02))
            XCTAssertTrue(cleanedUp)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectionDeadlinePropagatesCancellation() async {
        let task = Task {
            try await ConnectionDeadline.run(timeout: 2, phase: .sshBootstrap) {
                try await Task.sleep(for: .seconds(1))
                return true
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testConnectionDeadlinePreservesOperationFailure() async {
        do {
            let _: Bool = try await ConnectionDeadline.run(timeout: 1, phase: .moshDetection) {
                throw ConnectionCoordinatorError.moshUnavailable
            }
            XCTFail("Expected the operation error")
        } catch let error as ConnectionCoordinatorError {
            XCTAssertEqual(error, .moshUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCoordinatorRejectsInvalidMoshPortRangeBeforeNetworkAccess() async {
        let server = Server(
            name: "Invalid",
            hostname: "not-a-real-host.invalid",
            username: "user",
            transportPolicy: .mosh,
            moshUDPPortRange: "70000"
        )
        let coordinator = ConnectionCoordinator()

        do {
            _ = try await coordinator.prepare(server: server, password: "unused", keyTag: nil)
            XCTFail("Expected the invalid Mosh range to be rejected")
        } catch let error as ConnectionCoordinatorError {
            XCTAssertEqual(error, .invalidMoshPortRange("70000"))
            XCTAssertNil(coordinator.sshSession)
            XCTAssertNil(coordinator.moshSession)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectionViewModelSurfacesInvalidMoshPortRange() async {
        let server = Server(
            name: "Invalid",
            hostname: "not-a-real-host.invalid",
            username: "user",
            transportPolicy: .mosh,
            moshUDPPortRange: "descending:range"
        )
        let viewModel = ConnectionViewModel()

        await viewModel.connect(server: server, password: "unused", keyTag: nil)

        XCTAssertTrue(viewModel.showError)
        XCTAssertTrue(viewModel.errorMessage?.contains("Invalid Mosh UDP port range") == true)
        XCTAssertFalse(viewModel.isConnecting)
    }

    func testShellEscapingProtectsTmuxSessionNames() {
        XCTAssertEqual(
            TmuxDetectionService.attachCommand(sessionName: "agent's session"),
            "tmux attach -t 'agent'\\''s session'"
        )
        XCTAssertEqual(MoshBootstrapService.shellEscape("a'b"), "'a'\\''b'")
    }

    func testMoshLaunchStartsChosenTmuxSessionInsideRemotePTY() throws {
        let range = try XCTUnwrap(MoshPortRange("60000:60010"))
        let command = MoshBootstrapService.serverLaunchCommand(
            configuredServerPath: "/opt/custom/mosh-server",
            portRange: range,
            initialCommand: TmuxDetectionService.attachCommand(sessionName: "coding agents")
        )

        XCTAssertTrue(command.contains("/opt/custom/mosh-server"))
        XCTAssertTrue(command.contains("60000:60010"))
        XCTAssertTrue(command.contains("tmux attach -t"))
        XCTAssertTrue(command.contains("coding agents"))
        XCTAssertTrue(command.contains(" -- sh -lc "))
    }

    func testRawMoshLaunchDoesNotInjectTmuxCommand() {
        let command = MoshBootstrapService.serverLaunchCommand(
            configuredServerPath: nil,
            portRange: nil,
            initialCommand: nil
        )

        XCTAssertTrue(command.contains("mosh-server"))
        XCTAssertFalse(command.contains(" -- sh -lc "))
    }

    func testMoshProtocolEngineRoundTripsEncryptedInstructions() async throws {
        let engine = try MoshProtocolEngine(key: Data(repeating: 0x42, count: 16))
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 7
        instruction.newNum = 8
        instruction.ackNum = 6

        let datagrams = try await engine.encode(instruction)
        let decoded = try await engine.decode(try XCTUnwrap(datagrams.first), direction: .toServer)

        XCTAssertEqual(datagrams.count, 1)
        XCTAssertEqual(decoded?.instruction.oldNum, 7)
        XCTAssertEqual(decoded?.instruction.newNum, 8)
        XCTAssertEqual(decoded?.instruction.ackNum, 6)
    }

    func testMoshProtocolEngineReassemblesOutOfOrderFragments() async throws {
        let engine = try MoshProtocolEngine(key: Data(repeating: 0x33, count: 16))
        var instruction = MoshTransportInstruction()
        instruction.newNum = 42
        instruction.chaff = noisyData(count: 12_000)

        let datagrams = try await engine.encode(instruction)
        XCTAssertGreaterThan(datagrams.count, 1)

        var decoded: MoshDecodedDatagram?
        for datagram in datagrams.reversed() {
            decoded = try await engine.decode(datagram, direction: .toServer) ?? decoded
        }

        XCTAssertEqual(decoded?.instruction.newNum, 42)
        XCTAssertEqual(decoded?.instruction.chaff, instruction.chaff)
    }

    func testMoshProtocolEngineWaitsForMissingFragment() async throws {
        let engine = try MoshProtocolEngine(key: Data(repeating: 0x24, count: 16))
        var instruction = MoshTransportInstruction()
        instruction.chaff = noisyData(count: 8_000)

        let datagrams = try await engine.encode(instruction)
        XCTAssertGreaterThan(datagrams.count, 1)

        for datagram in datagrams.dropLast() {
            let partial = try await engine.decode(datagram, direction: .toServer)
            XCTAssertNil(partial)
        }
        let complete = try await engine.decode(try XCTUnwrap(datagrams.last), direction: .toServer)
        XCTAssertEqual(complete?.instruction.chaff, instruction.chaff)
    }

    func testMoshProtocolEngineRejectsTamperedDatagram() async throws {
        let engine = try MoshProtocolEngine(key: Data(repeating: 0x55, count: 16))
        let datagram = try await engine.encode(MoshTransportInstruction())
        var corrupted = try XCTUnwrap(datagram.first)
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0xFF

        do {
            _ = try await engine.decode(corrupted, direction: .toServer)
            XCTFail("Expected authenticated decryption to reject tampered data")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testDefaultMoshUDPHandshakeTimeoutIsBounded() {
        XCTAssertEqual(ConnectionTimeouts.default.udpConnection, 8)
    }

    func testReadyUDPSocketWithoutAuthenticatedServerResponseTimesOut() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()

        do {
            try await session.establishUDP(info: info, timeout: 0.06)
            XCTFail("Expected a silent UDP endpoint to time out")
        } catch let error as MoshUDPError {
            guard case .noServerResponse(let host, let port, let seconds) = error else {
                return XCTFail("Expected a silent-server error, got \(error)")
            }
            XCTAssertEqual(host, "127.0.0.1")
            XCTAssertEqual(port, 60001)
            XCTAssertEqual(seconds, 0.06, accuracy: 0.001)
        }

        XCTAssertFalse(transport.isReady)
        XCTAssertEqual(transport.sentDatagrams.count, 1)
        XCTAssertNotEqual(session.connectionState, .connected)
    }

    func testAuthenticatedServerResponseConnectsWithoutTerminalOutput() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()
        let response = try await makeServerDatagrams(key: info.sessionKey).first!
        transport.onSend = { transport.yield(response) }

        try await session.establishUDP(info: info, timeout: 1)

        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertEqual(session.debugStats.decryptSuccesses, 1)
        XCTAssertEqual(session.debugStats.decodedHostBytes, 0)
        XCTAssertEqual(transport.sentDatagrams.count, 1)
        await session.disconnect()
    }

    func testUnauthenticatedResponseCannotMarkMoshConnected() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()
        var invalidResponse = try await makeServerDatagrams(key: info.sessionKey).first!
        invalidResponse[invalidResponse.index(before: invalidResponse.endIndex)] ^= 0xFF
        transport.onSend = { transport.yield(invalidResponse) }

        do {
            try await session.establishUDP(info: info, timeout: 0.06)
            XCTFail("Expected an unauthenticated server response to be rejected")
        } catch let error as MoshUDPError {
            guard case .noServerResponse = error else {
                return XCTFail("Expected a silent-server error, got \(error)")
            }
        }

        XCTAssertNotEqual(session.connectionState, .connected)
        XCTAssertEqual(session.debugStats.decryptSuccesses, 0)
        XCTAssertFalse(transport.isReady)
    }

    func testMoshRetriesInitialProbeBeforeServerResponds() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()
        let response = try await makeServerDatagrams(key: info.sessionKey).first!
        transport.onSend = {
            if transport.sentDatagrams.count == 2 {
                transport.yield(response)
            }
        }

        try await session.establishUDP(info: info, timeout: 1)

        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertEqual(transport.sentDatagrams.count, 2)
        await session.disconnect()
    }

    func testFragmentedServerResponseWaitsForCompleteAuthenticatedInstruction() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()
        var instruction = MoshTransportInstruction()
        instruction.chaff = noisyData(count: 12_000)
        let datagrams = try await makeServerDatagrams(key: info.sessionKey, instruction: instruction)
        XCTAssertGreaterThan(datagrams.count, 1)

        transport.onSend = {
            transport.yield(datagrams[0])
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(25))
                for datagram in datagrams.dropFirst() {
                    transport.yield(datagram)
                }
            }
        }

        let connection = Task {
            try await session.establishUDP(info: info, timeout: 1)
        }

        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNotEqual(session.connectionState, .connected)

        try await connection.value
        XCTAssertEqual(session.connectionState, .connected)
        await session.disconnect()
    }

    func testCancellingMoshHandshakeCleansUpWithoutConnectedState() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()
        let connection = Task {
            try await session.establishUDP(info: info, timeout: 5)
        }

        let probeDeadline = Date().addingTimeInterval(1)
        while transport.sentDatagrams.isEmpty, Date() < probeDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(transport.sentDatagrams.isEmpty)

        connection.cancel()

        do {
            try await connection.value
            XCTFail("Expected Mosh startup cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(transport.isReady)
        XCTAssertNotEqual(session.connectionState, .connected)
    }

    func testMoshResumeReconnectsOnlyAfterAuthenticatedResponse() async throws {
        let transport = FakeMoshUDPTransport()
        let session = makeMoshSession(transport: transport)
        let info = makeMoshConnectionInfo()
        let response = try await makeServerDatagrams(key: info.sessionKey).first!
        transport.onSend = { transport.yield(response) }
        try await session.establishUDP(info: info, timeout: 1)

        await session.handleAppResume()

        XCTAssertEqual(transport.connectCount, 2)
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertEqual(session.recoveryStatus, .idle)
        await session.disconnect()
    }

    func testMoshRecoveryExhaustionBlocksInputAndExposesActions() async throws {
        let transport = FakeMoshUDPTransport()
        let policy = ReconnectionPolicy(
            initialDelay: 0.01,
            maximumDelay: 0.01,
            maximumAttempts: .max,
            foregroundBudget: 0.08,
            attemptTimeout: 0.03
        )
        let session = makeMoshSession(transport: transport, policy: policy)
        let info = makeMoshConnectionInfo()
        let response = try await makeServerDatagrams(key: info.sessionKey).first!
        transport.onSend = { transport.yield(response) }
        try await session.establishUDP(info: info, timeout: 1)
        transport.onSend = nil

        await session.handleAppResume()

        guard case .unavailable = session.recoveryStatus else {
            return XCTFail("Expected unavailable recovery status, got \(session.recoveryStatus)")
        }
        guard case .error = session.connectionState else {
            return XCTFail("Expected terminal error state, got \(session.connectionState)")
        }

        let viewModel = ConnectionViewModel()
        viewModel.moshSession = session
        XCTAssertFalse(viewModel.canAcceptTerminalInput)
        await session.disconnect()
    }

    func testAutoTransportMayFallBackWhenMoshServerNeverResponds() {
        let error = MoshUDPError.noServerResponse(host: "127.0.0.1", port: 60001, seconds: 8)

        XCTAssertTrue(ConnectionCoordinator.shouldFallback(after: error))
        XCTAssertEqual(ConnectionTransportPolicy.auto.candidateTransports, [.mosh, .ssh])
        XCTAssertEqual(ConnectionTransportPolicy.mosh.candidateTransports, [.mosh])
    }

    func testAutomaticFallbackRemainsVisibleWithItsExactUnderlyingReason() {
        let server = Server(
            name: "Agents",
            hostname: "agents.example.com",
            username: "user",
            transportPolicy: .auto
        )
        let error = MoshUDPError.noServerResponse(
            host: "agents.example.com",
            port: 60217,
            seconds: 8
        )
        let viewModel = ConnectionViewModel()

        viewModel.presentTransportFallback(error, server: server)

        let notice = viewModel.transportFallbackNotice
        XCTAssertEqual(notice?.title, "Mosh Server Is Not Responding")
        XCTAssertTrue(notice?.explanation.contains("agents.example.com:60217") == true)
        XCTAssertTrue(notice?.technicalDetails.contains("noServerResponse") == true)
        XCTAssertEqual(notice?.context.phase, ConnectionPhase.sshFallback.statusText)
    }

    func testMoshUnavailableFallbackHasSpecificVisibleReason() {
        let server = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let viewModel = ConnectionViewModel()

        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: server)

        XCTAssertEqual(viewModel.transportFallbackNotice?.title, "Mosh Is Not Installed")
    }

    func testFallbackNoticeCanBeDismissedAndDoesNotTreatCancellationAsFailure() {
        let server = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let viewModel = ConnectionViewModel()

        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: server)
        XCTAssertNotNil(viewModel.transportFallbackNotice)

        viewModel.dismissTransportFallbackNotice()
        XCTAssertNil(viewModel.transportFallbackNotice)

        viewModel.presentTransportFallback(CancellationError(), server: server)
        XCTAssertNil(viewModel.transportFallbackNotice)
    }

    func testDismissingFallbackKeepsAutomaticTransportForFutureConnections() {
        let server = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let viewModel = ConnectionViewModel()
        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: server)

        viewModel.dismissTransportFallbackNotice()

        XCTAssertNil(viewModel.transportFallbackNotice)
        XCTAssertEqual(server.transportPolicy, .auto)
        XCTAssertEqual(server.transportPolicy.candidateTransports, [.mosh, .ssh])
    }

    func testOnlyConnectedAutomaticSSHFallbackCanBecomePermanent() {
        let automatic = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let viewModel = ConnectionViewModel()
        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: automatic)

        XCTAssertFalse(viewModel.canRememberSSHFallback)

        let sshSession = SSHSession(server: automatic)
        sshSession.connectionState = .connected
        viewModel.sshSession = sshSession
        XCTAssertTrue(viewModel.canRememberSSHFallback)

        sshSession.connectionState = .disconnected
        XCTAssertFalse(viewModel.canRememberSSHFallback)

        sshSession.connectionState = .connected
        let moshOnly = Server(name: "Strict", hostname: "example.com", username: "user", transportPolicy: .mosh)
        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: moshOnly)
        XCTAssertFalse(viewModel.canRememberSSHFallback)

        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: automatic)
        XCTAssertTrue(viewModel.canRememberSSHFallback)
        viewModel.dismissTransportFallbackNotice()
        XCTAssertFalse(viewModel.canRememberSSHFallback)
    }

    func testFallbackNoticeClearsWhenStartingAnotherConnection() async {
        let original = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let viewModel = ConnectionViewModel()
        viewModel.presentTransportFallback(ConnectionCoordinatorError.moshUnavailable, server: original)

        let next = Server(
            name: "Next",
            hostname: "example.com",
            username: "user",
            authMethod: .key,
            transportPolicy: .ssh
        )
        await viewModel.connect(server: next, password: nil, keyTag: nil)

        XCTAssertNil(viewModel.transportFallbackNotice)
    }

    func testAutoSessionReportsActualSSHTransportAfterFallback() {
        let server = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let session = ManagedSession(server: server)
        session.connectionVM.sshSession = SSHSession(server: server)

        XCTAssertFalse(session.isMosh)
    }

    func testMoshNonceSeparatesClientAndServerDirections() {
        let outbound = MoshNonce(direction: .toServer, sequenceNumber: 17)
        let inbound = MoshNonce(direction: .toClient, sequenceNumber: 17)

        XCTAssertNotEqual(outbound.wireBytes, inbound.wireBytes)
        XCTAssertEqual(outbound.sequenceNumber, 17)
        XCTAssertEqual(inbound.sequenceNumber, 17)
    }

    func testMoshCryptoRejectsInvalidSessionKey() {
        XCTAssertThrowsError(try MoshCryptoSession(key: Data(repeating: 0, count: 15)))
    }

    func testMoshCryptoRejectsReflectedClientDatagrams() throws {
        let crypto = try MoshCryptoSession(key: Data(repeating: 0x21, count: 16))
        let datagram = try crypto.encrypt(
            plaintext: Data("client input".utf8),
            nonce: MoshNonce(direction: .toServer, sequenceNumber: 1)
        )

        XCTAssertThrowsError(try crypto.decrypt(datagram: datagram, direction: .toClient)) { error in
            guard case MoshCryptoError.unexpectedDirection = error else {
                return XCTFail("Expected an invalid-direction error, got \(error)")
            }
        }
    }

    func testSSHOutputBufferReplaysBinaryDataExactlyOnce() async {
        let server = makeServer()
        let session = SSHSession(server: server)
        let viewModel = ConnectionViewModel()
        viewModel.sshSession = session
        let bytes = Data([0x1B, 0x5B, 0x32, 0x4A, 0xFF, 0x00])
        session.bufferTerminalOutput(bytes)
        let received = CallbackRecorder()

        viewModel.setDataCallback { bytes in Task { await received.append(bytes) } }
        viewModel.setDataCallback { bytes in Task { await received.append(bytes) } }
        try? await Task.sleep(for: .milliseconds(20))

        let outputs = await received.outputs
        XCTAssertEqual(outputs, [Array(bytes)])
    }

    func testMoshOutputBufferReplaysBinaryDataExactlyOnce() async {
        let server = Server(name: "Mosh", hostname: "example.com", username: "user", useMosh: true)
        let session = MoshSession(server: server)
        let viewModel = ConnectionViewModel()
        viewModel.moshSession = session
        let bytes = Data([0x1B, 0x5D, 0x35, 0x32, 0x3B, 0xFF])
        session.bufferTerminalOutput(bytes)
        let received = CallbackRecorder()

        viewModel.setDataCallback { bytes in Task { await received.append(bytes) } }
        viewModel.setDataCallback { bytes in Task { await received.append(bytes) } }
        try? await Task.sleep(for: .milliseconds(20))

        let outputs = await received.outputs
        XCTAssertEqual(outputs, [Array(bytes)])
    }

    func testPersistenceStoreRoundTripsSessionDescriptors() {
        let store = SessionPersistenceStore(defaults: defaults)
        let descriptor = PersistedSessionDescriptor(
            id: UUID(),
            serverID: UUID(),
            serverName: "Agents",
            transportPolicy: .auto,
            tmuxSession: "coding",
            createdAt: Date(timeIntervalSince1970: 100),
            lastAccessedAt: Date(timeIntervalSince1970: 200)
        )

        store.save([descriptor])

        XCTAssertEqual(store.load(), [descriptor])
    }

    func testPersistenceStoreClearsEmptySessionLists() {
        let store = SessionPersistenceStore(defaults: defaults)
        let descriptor = makeDescriptor(serverID: UUID())
        store.save([descriptor])

        store.save([])

        XCTAssertTrue(store.load().isEmpty)
    }

    func testSessionDescriptorsExcludeCredentialsAndTerminalContents() throws {
        let store = SessionPersistenceStore(defaults: defaults, key: "descriptor")
        let descriptor = makeDescriptor(serverID: UUID(), tmuxSession: "coding")
        store.save([descriptor])

        let data = try XCTUnwrap(defaults.data(forKey: "descriptor"))
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(serialized.contains("password"))
        XCTAssertFalse(serialized.contains("privateKey"))
        XCTAssertFalse(serialized.contains("thumbnail"))
        XCTAssertFalse(serialized.contains("outputBuffer"))
    }

    func testSessionManagerRestoresIdentityTmuxAndAccessOrder() {
        let server = makeServer()
        let descriptor = makeDescriptor(serverID: server.id, tmuxSession: "restored-agent")
        let store = SessionPersistenceStore(defaults: defaults)
        store.save([descriptor])
        let manager = SessionManager(persistenceStore: store)

        let restored = manager.restoreSessions(using: [server])

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, descriptor.id)
        XCTAssertEqual(restored.first?.serverID, server.id)
        XCTAssertEqual(restored.first?.tmuxSession, "restored-agent")
        XCTAssertEqual(restored.first?.lastAccessedAt, descriptor.lastAccessedAt)
    }

    func testSessionManagerIgnoresRemovedServerProfiles() {
        let store = SessionPersistenceStore(defaults: defaults)
        store.save([makeDescriptor(serverID: UUID())])
        let manager = SessionManager(persistenceStore: store)

        XCTAssertTrue(manager.restoreSessions(using: [makeServer()]).isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSessionManagerDoesNotRestoreTwice() {
        let server = makeServer()
        let store = SessionPersistenceStore(defaults: defaults)
        store.save([makeDescriptor(serverID: server.id)])
        let manager = SessionManager(persistenceStore: store)

        XCTAssertEqual(manager.restoreSessions(using: [server]).count, 1)
        XCTAssertTrue(manager.restoreSessions(using: [server]).isEmpty)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testSessionManagerKeepsGhosttySurfaceWhenSwitchingSessions() throws {
        let store = SessionPersistenceStore(defaults: defaults)
        let manager = SessionManager(persistenceStore: store)
        let first = try XCTUnwrap(manager.createSession(for: makeServer(name: "First")))
        let second = try XCTUnwrap(manager.createSession(for: makeServer(name: "Second")))
        let surface = GhosttyTerminalSurfaceView(
            app: GhosttyRuntimeController.shared.app,
            fontSize: 14,
            keyboardVisible: false
        )
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        surface.layoutIfNeeded()
        surface.writeRemoteOutput(Array("preserved screen state".utf8))
        surface.selectAll(nil)
        first.surfaceView = surface

        manager.switchTo(sessionID: first.id)
        manager.switchTo(sessionID: second.id)
        manager.switchTo(sessionID: first.id)

        XCTAssertTrue(first.surfaceView === surface)
        XCTAssertTrue(first.surfaceView?.readSelection()?.contains("preserved screen state") == true)
    }

    func testSessionManagerPersistsChangesWhenTmuxSessionUpdates() throws {
        let store = SessionPersistenceStore(defaults: defaults)
        let manager = SessionManager(persistenceStore: store)
        let session = try XCTUnwrap(manager.createSession(for: makeServer()))

        session.tmuxSession = "updated-agent"
        manager.recordSessionUpdate(session)

        XCTAssertEqual(store.load().first?.tmuxSession, "updated-agent")
    }

    func testAlwaysUsingSSHPersistsCanonicalProfileAndUpdatesDetachedSessions() throws {
        let container = try ModelContainer(
            for: Server.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let server = Server(
            name: "Agents",
            hostname: "agents.example.com",
            username: "user",
            authMethod: .key,
            keyID: "agent-key",
            tmuxSession: "coding",
            transportPolicy: .auto,
            tmuxPolicy: .autoAttachLast,
            moshServerPath: "/opt/homebrew/bin/mosh-server",
            moshUDPPortRange: "60001:60010"
        )
        let other = Server(name: "Other", hostname: "other.example.com", username: "user", transportPolicy: .auto)
        context.insert(server)
        context.insert(other)
        try context.save()

        let store = SessionPersistenceStore(defaults: defaults)
        let manager = SessionManager(persistenceStore: store)
        let first = try XCTUnwrap(manager.createSession(for: detachedCopy(of: server)))
        let second = try XCTUnwrap(manager.createSession(for: detachedCopy(of: server)))
        let unaffected = try XCTUnwrap(manager.createSession(for: detachedCopy(of: other)))
        let activeSSH = SSHSession(server: first.server)
        activeSSH.connectionState = .connected
        first.connectionVM.sshSession = activeSSH
        let activeMosh = MoshSession(server: second.server)
        activeMosh.connectionState = .connected
        second.connectionVM.moshSession = activeMosh

        try manager.preferSSH(for: first, persistedServer: server) {
            try context.save()
        }

        let reloadedContext = ModelContext(container)
        let profiles = try reloadedContext.fetch(FetchDescriptor<Server>())
        let saved = try XCTUnwrap(profiles.first { $0.id == server.id })
        XCTAssertEqual(saved.transportPolicy, .ssh)
        XCTAssertEqual(saved.transportPolicyRawValue, ConnectionTransportPolicy.ssh.rawValue)
        XCTAssertFalse(saved.useMosh)
        XCTAssertEqual(saved.transportPolicy.candidateTransports, [.ssh])
        XCTAssertEqual(saved.keyID, "agent-key")
        XCTAssertEqual(saved.tmuxPolicy, .autoAttachLast)
        XCTAssertEqual(saved.tmuxSession, "coding")
        XCTAssertEqual(saved.moshServerPath, "/opt/homebrew/bin/mosh-server")
        XCTAssertEqual(saved.moshUDPPortRange, "60001:60010")

        XCTAssertEqual(first.transportPolicy, .ssh)
        XCTAssertEqual(second.transportPolicy, .ssh)
        XCTAssertEqual(unaffected.transportPolicy, .auto)
        XCTAssertEqual(other.transportPolicy, .auto)
        XCTAssertTrue(first.connectionVM.sshSession === activeSSH)
        XCTAssertEqual(activeSSH.connectionState, .connected)
        XCTAssertTrue(second.connectionVM.moshSession === activeMosh)
        XCTAssertTrue(second.isMosh)

        let descriptors = store.load()
        XCTAssertEqual(descriptors.first { $0.id == first.id }?.transportPolicy, .ssh)
        XCTAssertEqual(descriptors.first { $0.id == second.id }?.transportPolicy, .ssh)
        XCTAssertEqual(descriptors.first { $0.id == unaffected.id }?.transportPolicy, .auto)

        let restoredManager = SessionManager(persistenceStore: store)
        let restored = restoredManager.restoreSessions(using: profiles)
        XCTAssertEqual(restored.first { $0.id == first.id }?.transportPolicy, .ssh)
        XCTAssertEqual(restored.first { $0.id == second.id }?.transportPolicy, .ssh)
        XCTAssertEqual(restored.first { $0.id == unaffected.id }?.transportPolicy, .auto)
    }

    func testAlwaysUsingSSHRollsBackProfileWhenSavingFails() throws {
        let server = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let store = SessionPersistenceStore(defaults: defaults)
        let manager = SessionManager(persistenceStore: store)
        let session = try XCTUnwrap(manager.createSession(for: detachedCopy(of: server)))
        let originalPolicy = server.transportPolicyRawValue
        let originalMoshPreference = server.useMosh
        let underlying = NSError(
            domain: "HoshiTests.ServerPreferenceStore",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "The server profile store is unavailable."]
        )

        XCTAssertThrowsError(try manager.preferSSH(for: session, persistedServer: server) {
            throw underlying
        }) { error in
            XCTAssertEqual((error as NSError).domain, underlying.domain)
            XCTAssertEqual((error as NSError).code, underlying.code)
        }

        XCTAssertEqual(server.transportPolicyRawValue, originalPolicy)
        XCTAssertEqual(server.useMosh, originalMoshPreference)
        XCTAssertEqual(server.transportPolicy, .auto)
        XCTAssertEqual(session.transportPolicy, .auto)
        XCTAssertEqual(store.load().first?.transportPolicy, .auto)
    }

    func testAlwaysUsingSSHRollsBackLegacyPolicyWithoutInventingRawValue() throws {
        let server = Server(name: "Legacy", hostname: "example.com", username: "user", useMosh: true)
        XCTAssertNil(server.transportPolicyRawValue)
        let manager = SessionManager(persistenceStore: SessionPersistenceStore(defaults: defaults))
        let session = try XCTUnwrap(manager.createSession(for: detachedCopy(of: server)))

        XCTAssertThrowsError(try manager.preferSSH(for: session, persistedServer: server) {
            throw NSError(domain: "HoshiTests.ServerPreferenceStore", code: 7)
        })

        XCTAssertNil(server.transportPolicyRawValue)
        XCTAssertTrue(server.useMosh)
        XCTAssertEqual(server.transportPolicy, .mosh)
        XCTAssertEqual(session.transportPolicy, .mosh)
    }

    func testAlwaysUsingSSHRejectsMissingProfileOrInactiveSession() throws {
        let server = Server(name: "Agents", hostname: "example.com", username: "user", transportPolicy: .auto)
        let other = Server(name: "Other", hostname: "other.example.com", username: "user", transportPolicy: .auto)
        let manager = SessionManager(persistenceStore: SessionPersistenceStore(defaults: defaults))
        let active = try XCTUnwrap(manager.createSession(for: detachedCopy(of: server)))
        let inactive = ManagedSession(server: detachedCopy(of: server))
        var saveCount = 0

        XCTAssertThrowsError(try manager.preferSSH(for: active, persistedServer: other) {
            saveCount += 1
        }) { error in
            XCTAssertEqual(error as? SessionTransportPreferenceError, .serverProfileUnavailable("Agents"))
        }

        XCTAssertThrowsError(try manager.preferSSH(for: inactive, persistedServer: server) {
            saveCount += 1
        }) { error in
            XCTAssertEqual(error as? SessionTransportPreferenceError, .sessionUnavailable("Agents"))
        }

        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(server.transportPolicy, .auto)
        XCTAssertEqual(other.transportPolicy, .auto)
    }

    func testBackgroundingReplacesTerminalThumbnailWithPrivacyCover() throws {
        let store = SessionPersistenceStore(defaults: defaults)
        let manager = SessionManager(persistenceStore: store)
        let session = try XCTUnwrap(manager.createSession(for: makeServer()))
        manager.switchTo(sessionID: session.id)

        manager.handleSceneBackground()

        let thumbnail = try XCTUnwrap(session.thumbnail)
        XCTAssertEqual(thumbnail.size, CGSize(width: 320, height: 190))
    }

    func testSessionManagerRemovesPersistedClosedSessions() async throws {
        let store = SessionPersistenceStore(defaults: defaults)
        let manager = SessionManager(persistenceStore: store)
        let session = try XCTUnwrap(manager.createSession(for: makeServer()))

        await manager.closeSession(id: session.id)

        XCTAssertTrue(store.load().isEmpty)
    }

    func testConnectionErrorMessagesAreActionable() {
        let timeout = ConnectionCoordinatorError.timedOut(phase: .udpConnection, seconds: 12)
        XCTAssertTrue(timeout.localizedDescription.contains("12 seconds"))
        XCTAssertTrue(ConnectionCoordinatorError.invalidMoshPortRange("bad").localizedDescription.contains("60000:61000"))
        XCTAssertTrue(ConnectionCoordinatorError.bootstrapUnavailable.localizedDescription.contains("Reconnect"))
    }

    private func makeServer(name: String = "Server") -> Server {
        Server(name: name, hostname: "example.com", username: "user")
    }

    private func detachedCopy(of server: Server) -> Server {
        let copy = Server(
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            keyID: server.keyID,
            useMosh: server.useMosh,
            isFavorite: server.isFavorite,
            tmuxSession: server.tmuxSession,
            transportPolicy: server.transportPolicyRawValue == nil ? nil : server.transportPolicy,
            tmuxPolicy: server.tmuxPolicyRawValue == nil ? nil : server.tmuxPolicy,
            moshServerPath: server.moshServerPath,
            moshUDPPortRange: server.moshUDPPortRange
        )
        copy.id = server.id
        return copy
    }

    private func makeMoshSession(
        transport: FakeMoshUDPTransport,
        policy: ReconnectionPolicy = .mosh
    ) -> MoshSession {
        MoshSession(
            server: Server(name: "Mosh", hostname: "127.0.0.1", username: "user", transportPolicy: .auto),
            reconnectionPolicy: policy,
            makeUDPConnection: { _, _ in transport }
        )
    }

    private func makeMoshConnectionInfo() -> MoshConnectionInfo {
        let key = Data(repeating: 0x42, count: 16)
        return MoshConnectionInfo(
            udpPort: 60001,
            sessionKey: key,
            sessionKeyBase64: key.base64EncodedString(),
            serverIP: "127.0.0.1"
        )
    }

    private func makeServerDatagrams(
        key: Data,
        instruction: MoshTransportInstruction = MoshTransportInstruction()
    ) async throws -> [Data] {
        let engine = try MoshProtocolEngine(key: key)
        let clientDatagrams = try await engine.encode(instruction)
        let crypto = try MoshCryptoSession(key: key)

        return try clientDatagrams.enumerated().map { index, datagram in
            let plaintext = try crypto.decrypt(datagram: datagram, direction: .toServer).plaintext
            return try crypto.encrypt(
                plaintext: plaintext,
                nonce: MoshNonce(direction: .toClient, sequenceNumber: UInt64(index + 1))
            )
        }
    }

    private func makeDescriptor(serverID: UUID, tmuxSession: String? = nil) -> PersistedSessionDescriptor {
        PersistedSessionDescriptor(
            id: UUID(),
            serverID: serverID,
            serverName: "Persisted",
            transportPolicy: .ssh,
            tmuxSession: tmuxSession,
            createdAt: Date(timeIntervalSince1970: 100),
            lastAccessedAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func noisyData(count: Int) -> Data {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        return Data((0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }
}

@MainActor
private final class FakeMoshUDPTransport: MoshUDPTransport {
    private(set) var isReady = false
    private(set) var sentDatagrams: [Data] = []
    private(set) var connectCount = 0
    var onSend: (() -> Void)?
    var connectError: Error?

    private var queuedDatagrams: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data, Error>] = []

    func connect() async throws {
        connectCount += 1
        if let connectError { throw connectError }
        isReady = true
    }

    func send(_ data: Data) async throws {
        guard isReady else { throw MoshUDPError.notConnected }
        sentDatagrams.append(data)
        onSend?()
    }

    func receive() async throws -> Data {
        guard isReady else { throw MoshUDPError.notConnected }
        if !queuedDatagrams.isEmpty {
            return queuedDatagrams.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func yield(_ data: Data) {
        if receiveWaiters.isEmpty {
            queuedDatagrams.append(data)
        } else {
            receiveWaiters.removeFirst().resume(returning: data)
        }
    }

    func disconnect() {
        isReady = false
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private actor CallbackRecorder {
    private(set) var outputs: [[UInt8]] = []

    func append(_ bytes: [UInt8]) {
        outputs.append(bytes)
    }
}
