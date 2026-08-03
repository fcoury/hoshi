import Foundation
import SwiftUI
import UserNotifications
import XCTest
@testable import Hoshi

@MainActor
final class AgentMonitoringTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "hoshi.agent-monitoring.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        CompanionURLProtocol.handler = nil
        super.tearDown()
    }

    func testAgentEventKindsExposeStableWireValues() {
        XCTAssertEqual(AgentEventKind.completed.rawValue, "completed")
        XCTAssertEqual(AgentEventKind.needsAttention.rawValue, "needs_attention")
        XCTAssertEqual(AgentEventKind.approvalRequested.rawValue, "approval_requested")
    }

    func testAgentEnvelopeRejectsUnsupportedVersionsAndBlankTitles() {
        XCTAssertFalse(makeEnvelope(version: 99).isValid)
        XCTAssertFalse(AgentEventEnvelope(kind: .completed, title: "  ").isValid)
    }

    func testAgentEnvelopeRejectsOversizedMessagesAndHostnames() {
        XCTAssertFalse(AgentEventEnvelope(kind: .completed, title: "Done", message: String(repeating: "x", count: 4_097)).isValid)
        XCTAssertFalse(AgentEventEnvelope(kind: .completed, title: "Done", hostname: String(repeating: "x", count: 256)).isValid)
    }

    func testAgentEnvelopeRejectsControlCharactersInVisibleMetadata() {
        XCTAssertFalse(AgentEventEnvelope(kind: .completed, title: "bad\u{1B}title").isValid)
        XCTAssertFalse(AgentEventEnvelope(kind: .completed, title: "Done", hostname: "host\nname").isValid)
        XCTAssertFalse(AgentEventEnvelope(kind: .completed, title: "Done", tmuxSession: "tmux\u{0}").isValid)
    }

    func testTerminalDecoderPreservesOrdinaryBinaryOutput() async {
        let decoder = AgentEventStreamDecoder()
        let output = Data([0x00, 0xFF, 0x1B, 0x5B, 0x32, 0x4A])

        let result = await decoder.ingest(output)

        XCTAssertEqual(result.terminalOutput, output)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testTerminalDecoderExtractsEventAndPreservesSurroundingOutput() async throws {
        let decoder = AgentEventStreamDecoder()
        let event = makeEnvelope(kind: .needsAttention)
        let marker = try AgentEventStreamDecoder.encode(event)

        let result = await decoder.ingest(Data("before ".utf8) + marker + Data(" after".utf8))

        XCTAssertEqual(String(data: result.terminalOutput, encoding: .utf8), "before  after")
        XCTAssertEqual(result.events, [event])
    }

    func testTerminalDecoderHandlesMarkersSplitAcrossEveryByte() async throws {
        let decoder = AgentEventStreamDecoder()
        let event = makeEnvelope()
        let bytes = Data("left".utf8) + (try AgentEventStreamDecoder.encode(event)) + Data("right".utf8)
        var output = Data()
        var decoded: [AgentEventEnvelope] = []

        for byte in bytes {
            let result = await decoder.ingest(Data([byte]))
            output.append(result.terminalOutput)
            decoded.append(contentsOf: result.events)
        }

        XCTAssertEqual(output, Data("leftright".utf8))
        XCTAssertEqual(decoded, [event])
    }

    func testTerminalDecoderAcceptsStringTerminator() async throws {
        let decoder = AgentEventStreamDecoder()
        let event = makeEnvelope()
        let bytes = try AgentEventStreamDecoder.encode(event, terminator: Data([0x1B, 0x5C]))

        let result = await decoder.ingest(bytes)

        XCTAssertEqual(result.events, [event])
        XCTAssertTrue(result.terminalOutput.isEmpty)
    }

    func testTerminalDecoderExtractsMultipleEventsFromOneChunk() async throws {
        let decoder = AgentEventStreamDecoder()
        let first = makeEnvelope(kind: .completed)
        let second = makeEnvelope(kind: .approvalRequested)
        let bytes = try AgentEventStreamDecoder.encode(first) + Data(" ".utf8)
            + AgentEventStreamDecoder.encode(second)

        let result = await decoder.ingest(bytes)

        XCTAssertEqual(result.events, [first, second])
        XCTAssertEqual(result.terminalOutput, Data(" ".utf8))
    }

    func testTerminalDecoderPreservesMalformedEventSequences() async {
        let decoder = AgentEventStreamDecoder()
        let malformed = AgentEventStreamDecoder.prefix + Data("not-base64".utf8) + Data([0x07])

        let result = await decoder.ingest(malformed)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.terminalOutput, malformed)
    }

    func testTerminalDecoderPreservesUnsupportedProtocolVersions() async throws {
        let decoder = AgentEventStreamDecoder()
        let bytes = try AgentEventStreamDecoder.encode(makeEnvelope(version: 5))

        let result = await decoder.ingest(bytes)

        XCTAssertEqual(result.terminalOutput, bytes)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testTerminalDecoderBoundsUnterminatedEventPayloads() async {
        let decoder = AgentEventStreamDecoder()
        let bytes = AgentEventStreamDecoder.prefix
            + Data(repeating: 0x41, count: AgentEventStreamDecoder.maximumEncodedPayloadBytes + 1)

        let result = await decoder.ingest(bytes)

        XCTAssertEqual(result.terminalOutput, bytes)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testTerminalDecoderPreservesUnrelatedOSCSequences() async {
        let decoder = AgentEventStreamDecoder()
        let title = Data([0x1B, 0x5D]) + Data("0;terminal title".utf8) + Data([0x07])

        let result = await decoder.ingest(title)

        XCTAssertEqual(result.terminalOutput, title)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testTerminalDecoderCarriesIncompletePrefixWithoutLosingEscapeBytes() async {
        let decoder = AgentEventStreamDecoder()

        let first = await decoder.ingest(Data("text".utf8) + Data([0x1B]))
        let second = await decoder.ingest(Data("[2J".utf8))

        XCTAssertEqual(first.terminalOutput, Data("text".utf8))
        XCTAssertEqual(second.terminalOutput, Data([0x1B]) + Data("[2J".utf8))
    }

    func testSSHSessionExtractsEventsWithoutLeakingMarkersIntoTerminal() async throws {
        let server = makeServer()
        let session = SSHSession(server: server)
        let event = makeEnvelope()
        var events: [AgentEventEnvelope] = []
        let recorder = AgentOutputRecorder()
        session.onAgentEvent = { events.append($0) }
        session.onDataReceived = { bytes in
            Task { await recorder.append(bytes) }
        }

        await session.processInboundOutput(Data("start".utf8) + (try AgentEventStreamDecoder.encode(event)))
        await Task.yield()
        let output = await recorder.outputs

        XCTAssertEqual(events, [event])
        XCTAssertEqual(output, [Array("start".utf8)])
    }

    func testSSHSessionBuffersFilteredOutputWhenSurfaceIsHidden() async throws {
        let server = makeServer()
        let session = SSHSession(server: server)
        let event = makeEnvelope()
        var received = false
        session.onAgentEvent = { _ in received = true }

        await session.processInboundOutput((try AgentEventStreamDecoder.encode(event)) + Data("shell".utf8))

        XCTAssertTrue(received)
        XCTAssertEqual(session.consumeBufferedTerminalOutput(), Data("shell".utf8))
    }

    func testMoshSessionExtractsEventsWithoutLeakingMarkersIntoTerminal() async throws {
        let session = MoshSession(server: makeServer())
        let event = makeEnvelope(kind: .approvalRequested)
        var events: [AgentEventEnvelope] = []
        session.onAgentEvent = { events.append($0) }

        let output = await session.processInboundOutput(
            Data("mosh".utf8) + (try AgentEventStreamDecoder.encode(event))
        )

        XCTAssertEqual(events, [event])
        XCTAssertEqual(output, Data("mosh".utf8))
    }

    func testSessionManagerRoutesTerminalEventsToTheirAuthenticatedSession() async throws {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let server = makeServer(name: "Trusted")
        let session = try XCTUnwrap(manager.createSession(for: server))
        let ssh = SSHSession(server: server)
        session.connectionVM.sshSession = ssh
        let spoofed = AgentEventEnvelope(
            kind: .needsAttention,
            title: "Review requested",
            hostname: "attacker.example",
            serverID: UUID(),
            sessionID: UUID()
        )

        await ssh.processInboundOutput(try AgentEventStreamDecoder.encode(spoofed))

        let stored = try XCTUnwrap(center.events.first)
        XCTAssertEqual(stored.serverID, server.id)
        XCTAssertEqual(stored.sessionID, session.id)
        XCTAssertEqual(stored.hostname, server.hostname)
        XCTAssertEqual(session.unreadAgentEventCount, 1)
        XCTAssertEqual(session.agentAttentionKind, .needsAttention)
    }

    func testInboxDeduplicatesEventsAcrossTerminalAndCompanion() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        let event = makeEnvelope()

        XCTAssertNotNil(center.ingest(event, from: session))
        XCTAssertNil(center.ingestCompanion(event))
        XCTAssertEqual(center.events.count, 1)
    }

    func testApprovalRequestsTakePriorityOverCompletionBadges() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        _ = center.ingest(makeEnvelope(kind: .completed), from: session)
        _ = center.ingest(makeEnvelope(kind: .approvalRequested), from: session)

        XCTAssertEqual(session.unreadAgentEventCount, 2)
        XCTAssertEqual(session.agentAttentionKind, .approvalRequested)
    }

    func testSwitchingToASessionMarksItsEventsRead() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        _ = center.ingest(makeEnvelope(), from: session)

        manager.switchTo(sessionID: session.id)

        XCTAssertEqual(center.unreadCount, 0)
        XCTAssertEqual(session.unreadAgentEventCount, 0)
        XCTAssertNil(session.agentAttentionKind)
    }

    func testInboxPersistsAndRestoresUnreadEvents() {
        let persistence = AgentEventPersistenceStore(defaults: defaults)
        let center = makeEventCenter(persistence: persistence)
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        let envelope = makeEnvelope()
        _ = center.ingest(envelope, from: session)

        let restored = makeEventCenter(persistence: persistence)

        XCTAssertEqual(restored.events.map(\.id), [envelope.id])
        XCTAssertEqual(restored.unreadCount, 1)
    }

    func testInboxCapsPersistedHistoryAtTwoHundredEvents() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!

        for index in 0..<205 {
            _ = center.ingest(
                AgentEventEnvelope(kind: .completed, title: "Event \(index)", timestamp: Date(timeIntervalSince1970: TimeInterval(index))),
                from: session
            )
        }

        XCTAssertEqual(center.events.count, 200)
        XCTAssertEqual(center.events.first?.title, "Event 204")
        XCTAssertEqual(center.events.last?.title, "Event 5")
    }

    func testMarkingAndRemovingEventsUpdatesSessionAttention() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        let first = makeEnvelope()
        let second = makeEnvelope(kind: .needsAttention)
        _ = center.ingest(first, from: session)
        _ = center.ingest(second, from: session)

        center.markRead(eventID: first.id)
        XCTAssertEqual(session.unreadAgentEventCount, 1)
        center.remove(eventID: second.id)
        XCTAssertEqual(session.unreadAgentEventCount, 0)
        XCTAssertEqual(center.events.count, 1)
    }

    func testTerminalEventsNeverPersistUntrustedApprovalCommands() async throws {
        let id = UUID()
        let object: [String: Any] = [
            "version": 1,
            "id": id.uuidString,
            "kind": "approval_requested",
            "title": "Approve changes",
            "command": "rm -rf /",
        ]
        let payload = try JSONSerialization.data(withJSONObject: object)
        let bytes = AgentEventStreamDecoder.prefix + Data(payload.base64EncodedString().utf8) + Data([0x07])
        let decoder = AgentEventStreamDecoder()
        let decoded = await decoder.ingest(bytes)
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        _ = center.ingest(try XCTUnwrap(decoded.events.first), from: session)

        let data = try XCTUnwrap(defaults.data(forKey: "app.gethoshi.agent-events"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("rm -rf"))
    }

    func testNotificationPermissionMustBeGrantedExplicitly() async {
        let notifier = MockAgentNotifications()
        notifier.authorizationGranted = false
        let center = makeEventCenter(notifier: notifier)

        await center.setNotificationsEnabled(true)

        XCTAssertFalse(center.notificationsEnabled)
        XCTAssertEqual(notifier.authorizationRequests, 1)
        XCTAssertNotNil(center.notificationError)
    }

    func testInactiveSessionEventsScheduleLocalNotifications() async {
        let notifier = MockAgentNotifications()
        let center = makeEventCenter(notifier: notifier)
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        await center.setNotificationsEnabled(true)

        _ = center.ingest(makeEnvelope(), from: session)
        await yieldUntil { !notifier.deliveredEvents.isEmpty }

        XCTAssertEqual(notifier.deliveredEvents.count, 1)
        XCTAssertEqual(notifier.badgeCounts.last, 1)
    }

    func testFocusedSessionCompletionDoesNotCreateRedundantNotification() async {
        let notifier = MockAgentNotifications()
        let center = makeEventCenter(notifier: notifier)
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        manager.switchTo(sessionID: session.id)
        await center.setNotificationsEnabled(true)

        _ = center.ingest(makeEnvelope(kind: .completed), from: session)
        await Task.yield()

        XCTAssertTrue(notifier.deliveredEvents.isEmpty)
    }

    func testTerminalDesktopNotificationHonorsExplicitRequestForFocusedSession() async throws {
        let notifier = MockAgentNotifications()
        let center = makeEventCenter(notifier: notifier)
        let manager = makeSessionManager(center)
        let session = try XCTUnwrap(manager.createSession(for: makeServer()))
        manager.switchTo(sessionID: session.id)
        await center.setNotificationsEnabled(true)
        let notification = try XCTUnwrap(TerminalDesktopNotification(
            title: "Codex",
            body: "Agent turn complete"
        ))

        session.connectionVM.onTerminalNotification?(notification)
        await yieldUntil { !notifier.deliveredEvents.isEmpty }

        let event = try XCTUnwrap(center.events.first)
        XCTAssertEqual(event.kind, .completed)
        XCTAssertEqual(event.sessionID, session.id)
        XCTAssertEqual(notifier.deliveredEvents.map(\.id), [event.id])
    }

    func testApprovalRequestNotifiesEvenForFocusedSession() async {
        let notifier = MockAgentNotifications()
        let center = makeEventCenter(notifier: notifier)
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        manager.switchTo(sessionID: session.id)
        await center.setNotificationsEnabled(true)

        _ = center.ingest(makeEnvelope(kind: .approvalRequested), from: session)
        await yieldUntil { !notifier.deliveredEvents.isEmpty }

        XCTAssertEqual(notifier.deliveredEvents.first?.kind, .approvalRequested)
    }

    func testImmediatelyReadEventDoesNotScheduleAStaleNotification() async {
        let notifier = MockAgentNotifications()
        let center = makeEventCenter(notifier: notifier)
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        await center.setNotificationsEnabled(true)
        let envelope = makeEnvelope()

        _ = center.ingest(envelope, from: session)
        center.markRead(eventID: envelope.id)
        await Task.yield()

        XCTAssertTrue(notifier.deliveredEvents.isEmpty)
    }

    func testAppLockRedactsSensitiveNotificationDetails() throws {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer(name: "Private Production"))!
        let event = try XCTUnwrap(center.ingest(
            AgentEventEnvelope(kind: .approvalRequested, title: "Secret deployment", message: "Production credentials changed"),
            from: session
        ))

        let content = AgentNotificationService.makeContent(for: event, badgeCount: 1, protectDetails: true)

        XCTAssertFalse(content.title.contains("Secret"))
        XCTAssertFalse(content.subtitle.contains("Production"))
        XCTAssertFalse(content.body.contains("credentials"))
        XCTAssertEqual(content.badge?.intValue, 1)
    }

    func testNotificationDeepLinkTargetsTheRelatedSessionWithoutApprovalCommands() throws {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let session = manager.createSession(for: makeServer())!
        let event = try XCTUnwrap(center.ingest(makeEnvelope(), from: session))

        let content = AgentNotificationService.makeContent(for: event, badgeCount: 1, protectDetails: false)
        let value = try XCTUnwrap(content.userInfo["deepLink"] as? String)
        let url = try XCTUnwrap(URL(string: value))

        XCTAssertEqual(AgentDeepLink(url: url), .session(sessionID: session.id, eventID: event.id))
        XCTAssertNil(content.userInfo["command"])
    }

    func testCompanionEventsResolveHostAndTmuxToMatchingSession() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let server = makeServer()
        let session = manager.createSession(for: server)!
        session.tmuxSession = "coding"
        let event = AgentEventEnvelope(
            kind: .needsAttention,
            title: "Review",
            hostname: server.hostname.uppercased(),
            tmuxSession: "coding"
        )

        let stored = center.ingestCompanion(event)

        XCTAssertEqual(stored?.sessionID, session.id)
        XCTAssertEqual(session.unreadAgentEventCount, 1)
    }

    func testAmbiguousCompanionEventsNeverChooseAnArbitrarySession() {
        let center = makeEventCenter()
        let manager = makeSessionManager(center)
        let server = makeServer()
        let first = manager.createSession(for: server)!
        let second = manager.createSession(for: server)!

        let event = center.ingestCompanion(
            AgentEventEnvelope(kind: .needsAttention, title: "Review", hostname: server.hostname)
        )

        XCTAssertNil(event?.sessionID)
        XCTAssertEqual(first.unreadAgentEventCount, 0)
        XCTAssertEqual(second.unreadAgentEventCount, 0)
    }

    func testCompanionConfigurationAcceptsHTTPSAndLocalhostOnly() {
        XCTAssertTrue(AgentCompanionConfiguration.isSecureEndpoint(URL(string: "https://agents.example.com/events")!))
        XCTAssertTrue(AgentCompanionConfiguration.isSecureEndpoint(URL(string: "http://127.0.0.1:8765/events")!))
        XCTAssertTrue(AgentCompanionConfiguration.isSecureEndpoint(URL(string: "http://localhost:8765/events")!))
        XCTAssertFalse(AgentCompanionConfiguration.isSecureEndpoint(URL(string: "http://agents.example.com/events")!))
        XCTAssertFalse(AgentCompanionConfiguration.isSecureEndpoint(URL(string: "https://user:pass@agents.example.com/events")!))
    }

    func testCompanionTokenIsNeverStoredInUserDefaults() throws {
        let tokens = MockCompanionTokens()
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: tokens)

        try configuration.configure(endpoint: "https://agents.example.com/events", token: "private-token-with-at-least-sixteen-characters")

        XCTAssertEqual(tokens.value, "private-token-with-at-least-sixteen-characters")
        XCTAssertEqual(defaults.string(forKey: "app.gethoshi.agent-companion.endpoint"), "https://agents.example.com/events")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("private-token") })
    }

    func testCompanionRejectsShortTokensAndInsecureEndpoints() {
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: MockCompanionTokens())

        XCTAssertThrowsError(try configuration.configure(endpoint: "https://agents.example.com/events", token: "short"))
        XCTAssertThrowsError(try configuration.configure(endpoint: "https://agents.example.com/events", token: "token-with-invalid-é-character"))
        XCTAssertThrowsError(try configuration.configure(endpoint: "http://agents.example.com/events", token: "valid-token-with-sixteen-characters"))
        XCTAssertThrowsError(try configuration.configure(endpoint: "not a url", token: "valid-token-with-sixteen-characters"))
    }

    func testChangingCompanionEndpointClearsPersistedCursor() throws {
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: MockCompanionTokens())
        try configuration.configure(endpoint: "https://one.example.com/events", token: "valid-token-with-sixteen-characters")
        configuration.updateCursor("42")

        try configuration.configure(endpoint: "https://two.example.com/events", token: "valid-token-with-sixteen-characters")

        XCTAssertNil(configuration.cursor)
        XCTAssertNil(defaults.string(forKey: "app.gethoshi.agent-companion.cursor"))
    }

    func testRemovingCompanionDeletesKeychainToken() throws {
        let tokens = MockCompanionTokens()
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: tokens)
        try configuration.configure(endpoint: "https://agents.example.com/events", token: "valid-token-with-sixteen-characters")

        try configuration.removeConfiguration()

        XCTAssertNil(tokens.value)
        XCTAssertNil(configuration.endpoint)
        XCTAssertFalse(configuration.isEnabled)
    }

    func testCompanionClientUsesBearerAuthorizationAndCursor() async throws {
        let event = makeEnvelope()
        let batch = AgentCompanionBatch(version: 1, events: [event], nextCursor: "8")
        CompanionURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertTrue(request.url?.absoluteString.contains("after=7") ?? false)
            return (200, try Self.encode(batch))
        }

        let client = makeHTTPClient()
        let result = try await client.fetchEvents(
            endpoint: URL(string: "https://agents.example.com/events")!,
            bearerToken: "test-token",
            cursor: "7"
        )

        XCTAssertEqual(result, batch)
    }

    func testCompanionClientRejectsUnauthorizedResponses() async {
        CompanionURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        let client = makeHTTPClient()

        do {
            _ = try await client.fetchEvents(
                endpoint: URL(string: "https://agents.example.com/events")!,
                bearerToken: "bad",
                cursor: nil
            )
            XCTFail("Expected unauthorized companion response")
        } catch {
            XCTAssertEqual(error as? AgentCompanionError, .httpStatus(401))
        }
    }

    func testCompanionClientRejectsUnsupportedVersion() async {
        CompanionURLProtocol.handler = { _ in
            (200, Data(#"{"version":2,"events":[],"nextCursor":"0"}"#.utf8))
        }
        let client = makeHTTPClient()

        do {
            _ = try await client.fetchEvents(
                endpoint: URL(string: "https://agents.example.com/events")!,
                bearerToken: "token",
                cursor: nil
            )
            XCTFail("Expected unsupported companion protocol version")
        } catch {
            XCTAssertEqual(error as? AgentCompanionError, .unsupportedVersion(2))
        }
    }

    func testCompanionClientRejectsOversizedResponses() async {
        CompanionURLProtocol.handler = { _ in
            (200, Data(repeating: 0x20, count: AgentCompanionClient.maximumResponseBytes + 1))
        }
        let client = makeHTTPClient()

        do {
            _ = try await client.fetchEvents(
                endpoint: URL(string: "https://agents.example.com/events")!,
                bearerToken: "token",
                cursor: nil
            )
            XCTFail("Expected oversized companion feed to be rejected")
        } catch {
            XCTAssertEqual(error as? AgentCompanionError, .responseTooLarge)
        }
    }

    func testCompanionMonitorImportsEventsAndAdvancesCursor() async throws {
        let tokens = MockCompanionTokens()
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: tokens)
        try configuration.configure(endpoint: "https://agents.example.com/events", token: "valid-token-with-sixteen-characters")
        let center = makeEventCenter()
        let client = StubCompanionClient(batch:
            AgentCompanionBatch(version: 1, events: [makeEnvelope()], nextCursor: "21")
        )
        let monitor = AgentCompanionMonitor(configuration: configuration, eventCenter: center, client: client)

        let count = try await monitor.syncOnce()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(center.events.count, 1)
        XCTAssertEqual(configuration.cursor, "21")
        XCTAssertNotNil(monitor.lastSync)
    }

    func testRestartingCompanionMonitorDoesNotLetOldTaskClearNewPoller() async throws {
        let tokens = MockCompanionTokens()
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: tokens)
        try configuration.configure(endpoint: "https://agents.example.com/events", token: "valid-token-with-sixteen-characters")
        let center = makeEventCenter()
        let client = StubCompanionClient(batch: AgentCompanionBatch(version: 1, events: [], nextCursor: "0"))
        let monitor = AgentCompanionMonitor(configuration: configuration, eventCenter: center, client: client)

        monitor.start()
        monitor.stop()
        monitor.start()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(monitor.isPolling)
        monitor.stop()
    }

    func testDeepLinksRoundTripForInboxSessionsAndServers() {
        let eventID = UUID()
        let sessionID = UUID()
        let serverID = UUID()
        let values: [AgentDeepLink] = [
            .inbox(eventID: nil),
            .inbox(eventID: eventID),
            .session(sessionID: sessionID, eventID: eventID),
            .server(serverID: serverID, eventID: nil),
        ]

        for value in values {
            XCTAssertEqual(AgentDeepLink(url: value.url), value)
        }
    }

    func testDeepLinksRejectUnknownSchemesAndInvalidIdentifiers() {
        XCTAssertNil(AgentDeepLink(url: URL(string: "https://hoshi/session/123")!))
        XCTAssertNil(AgentDeepLink(url: URL(string: "hoshi://session/not-a-uuid")!))
        XCTAssertNil(AgentDeepLink(url: URL(string: "hoshi://inbox?event=invalid")!))
        XCTAssertNil(AgentDeepLink(url: URL(string: "hoshi://unknown")!))
    }

    func testHoshiURLSchemeIsRegisteredInApplicationInfoPlist() {
        let entries = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = entries?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes?.contains("hoshi") ?? false)
    }

    private func makeEnvelope(
        version: Int = AgentEventEnvelope.supportedVersion,
        kind: AgentEventKind = .completed
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(version: version, kind: kind, title: "Agent update", message: "Review the result")
    }

    private func makeServer(name: String = "Agents") -> Server {
        Server(name: name, hostname: "agents.example.com", username: "developer")
    }

    private func makeEventCenter(
        persistence: AgentEventPersistenceStore? = nil,
        notifier: MockAgentNotifications? = nil
    ) -> AgentEventCenter {
        AgentEventCenter(
            persistence: persistence ?? AgentEventPersistenceStore(defaults: defaults),
            notifications: notifier ?? MockAgentNotifications(),
            defaults: defaults
        )
    }

    private func makeSessionManager(_ center: AgentEventCenter) -> SessionManager {
        SessionManager(
            persistenceStore: SessionPersistenceStore(defaults: defaults),
            agentEventCenter: center
        )
    }

    private func makeHTTPClient() -> AgentCompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionURLProtocol.self]
        return AgentCompanionClient(session: URLSession(configuration: configuration))
    }

    private static func encode(_ batch: AgentCompanionBatch) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(batch)
    }

    private func yieldUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class MockAgentNotifications: AgentNotificationDelivering {
    var authorizationGranted = true
    private(set) var authorizationRequests = 0
    private(set) var deliveredEvents: [AgentInboxEvent] = []
    private(set) var badgeCounts: [Int] = []
    private(set) var removedIdentifiers: [UUID] = []

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func deliver(_ event: AgentInboxEvent, badgeCount: Int) async throws {
        deliveredEvents.append(event)
        badgeCounts.append(badgeCount)
    }

    func remove(eventID: UUID) {
        removedIdentifiers.append(eventID)
    }

    func setBadgeCount(_ count: Int) async {
        badgeCounts.append(count)
    }
}

@MainActor
private final class MockCompanionTokens: AgentCompanionTokenStoring {
    var value: String?

    func load() throws -> String? { value }
    func save(_ token: String) throws { value = token }
    func delete() throws { value = nil }
}

private actor StubCompanionClient: AgentCompanionFetching {
    let batch: AgentCompanionBatch

    init(batch: AgentCompanionBatch) {
        self.batch = batch
    }

    func fetchEvents(endpoint: URL, bearerToken: String, cursor: String?) async throws -> AgentCompanionBatch {
        batch
    }
}

private actor AgentOutputRecorder {
    private(set) var outputs: [[UInt8]] = []

    func append(_ bytes: [UInt8]) {
        outputs.append(bytes)
    }
}

private final class CompanionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
