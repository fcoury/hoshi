import Foundation
import XCTest
@testable import Hoshi

@MainActor
final class AgentLiveActivityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var provider: MockAgentLiveActivityProvider!
    private var appLockEnabled = false

    override func setUp() {
        super.setUp()
        suiteName = "hoshi.agent-live-activity.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        provider = MockAgentLiveActivityProvider()
        appLockEnabled = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        provider = nil
        super.tearDown()
    }

    func testLiveActivitiesRequireExplicitOptInAndHideServerNamesByDefault() {
        let service = makeService()
        let session = makeSession()

        service.synchronize(sessions: [session], events: [])

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.showsServerNames)
        XCTAssertTrue(provider.started.isEmpty)
    }

    func testUnavailableSystemLiveActivitiesFailClosedWithActionableError() {
        provider.areActivitiesEnabled = false
        let service = makeService()

        service.setEnabled(true, sessions: [makeSession()], events: [])

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.areActivitiesAvailable)
        XCTAssertTrue(provider.started.isEmpty)
        XCTAssertEqual(service.presentedError?.title, "Live Activity Failed")
        XCTAssertTrue(service.presentedError?.recoverySuggestion?.contains("iOS Settings") == true)
    }

    func testEnablingCreatesOnePrivacySafeActivityPerSession() throws {
        let service = makeService()
        let session = makeSession(name: "Private Production", tmux: "secret-work")

        service.setEnabled(true, sessions: [session], events: [])
        service.synchronize(sessions: [session], events: [])

        let activity = try XCTUnwrap(provider.started.first)
        XCTAssertEqual(provider.started.count, 1)
        XCTAssertEqual(activity.attributes.sessionID, session.id)
        XCTAssertEqual(activity.state.status, .running)
        XCTAssertEqual(activity.state.displayName, "Coding Agent")
        XCTAssertNil(activity.state.tmuxSession)
        XCTAssertTrue(activity.state.detailsAreHidden)
    }

    func testExplicitServerNamesAppearOnlyWhenAppLockIsDisabled() async throws {
        let service = makeService()
        let session = makeSession(name: "Private Production", tmux: "coding")
        service.setEnabled(true, sessions: [session], events: [])

        service.setShowsServerNames(true, sessions: [session], events: [])
        await waitUntil { self.provider.updated.count == 1 }

        let visible = try XCTUnwrap(provider.updated.last?.state)
        XCTAssertEqual(visible.displayName, "Private Production")
        XCTAssertEqual(visible.tmuxSession, "coding")
        XCTAssertFalse(visible.detailsAreHidden)

        appLockEnabled = true
        service.synchronize(sessions: [session], events: [])
        await waitUntil { self.provider.updated.count == 2 }

        let hidden = try XCTUnwrap(provider.updated.last?.state)
        XCTAssertEqual(hidden.displayName, "Coding Agent")
        XCTAssertNil(hidden.tmuxSession)
        XCTAssertTrue(hidden.detailsAreHidden)
        XCTAssertTrue(service.showsServerNames)
    }

    func testLiveActivityMetadataStripsControlCharactersAndBoundsLength() async throws {
        let service = makeService()
        let malicious = "prod\n\u{1B}[31m" + String(repeating: "x", count: 100)
        let session = makeSession(name: malicious, tmux: "tmux\nsecret")
        service.setEnabled(true, sessions: [session], events: [])
        service.setShowsServerNames(true, sessions: [session], events: [])
        await waitUntil { !self.provider.updated.isEmpty }

        let state = try XCTUnwrap(provider.updated.last?.state)
        XCTAssertFalse(state.displayName.contains("\n"))
        XCTAssertFalse(state.displayName.contains("\u{1B}"))
        XCTAssertLessThanOrEqual(state.displayName.count, 64)
        XCTAssertEqual(state.tmuxSession, "tmuxsecret")
    }

    func testApprovalRequestsTakePriorityAndNeverExposeEventContents() async throws {
        let service = makeService()
        let session = makeSession(name: "Production")
        service.setEnabled(true, sessions: [session], events: [])
        let completed = makeEvent(for: session, kind: .completed, title: "secret deployment details")
        let approval = makeEvent(
            for: session,
            kind: .approvalRequested,
            title: "private shell output",
            message: "token=super-secret"
        )

        service.synchronize(sessions: [session], events: [completed, approval])
        await waitUntil { !self.provider.updated.isEmpty }

        let state = try XCTUnwrap(provider.updated.last?.state)
        XCTAssertEqual(state.status, .approvalRequested)
        XCTAssertEqual(state.attentionCount, 2)
        XCTAssertEqual(state.latestEventID, approval.id)

        let encoded = String(data: try JSONEncoder().encode(state), encoding: .utf8)
        XCTAssertFalse(encoded?.contains("private shell output") == true)
        XCTAssertFalse(encoded?.contains("super-secret") == true)
        XCTAssertFalse(encoded?.contains("secret deployment") == true)
        XCTAssertFalse(encoded?.contains("Production") == true)
    }

    func testUnreadAttentionCountIsBounded() async throws {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])
        let events = (0..<120).map { _ in
            makeEvent(for: session, kind: .needsAttention, title: "Attention")
        }

        service.synchronize(sessions: [session], events: events)
        await waitUntil { !self.provider.updated.isEmpty }

        XCTAssertEqual(provider.updated.last?.state.attentionCount, 99)
        XCTAssertEqual(provider.updated.last?.state.status, .needsAttention)
    }

    func testMarkingEventsReadReturnsActivityToRunning() async throws {
        let service = makeService()
        let session = makeSession()
        let event = makeEvent(for: session, kind: .needsAttention, title: "Review")
        service.setEnabled(true, sessions: [session], events: [event])

        var read = event
        read.readAt = Date()
        service.synchronize(sessions: [session], events: [read])
        await waitUntil { !self.provider.updated.isEmpty }

        XCTAssertEqual(provider.updated.last?.state.status, .running)
        XCTAssertEqual(provider.updated.last?.state.attentionCount, 0)
        XCTAssertNil(provider.updated.last?.state.latestEventID)
    }

    func testCompletionUpdatesActivityWithoutEndingItsSession() async throws {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])
        let event = makeEvent(for: session, kind: .completed, title: "Finished")

        service.synchronize(sessions: [session], events: [event])
        await waitUntil { !self.provider.updated.isEmpty }

        XCTAssertEqual(provider.updated.last?.state.status, .completed)
        XCTAssertTrue(provider.ended.isEmpty)
    }

    func testClosingSessionImmediatelyEndsItsLiveActivity() async {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])

        service.endSession(id: session.id)
        await waitUntil { !self.provider.ended.isEmpty }

        XCTAssertEqual(provider.ended.first?.attributes.sessionID, session.id)
        XCTAssertTrue(provider.ended.first?.immediately == true)
    }

    func testDisablingImmediatelyEndsAllActivities() async {
        let service = makeService()
        let first = makeSession()
        let second = makeSession()
        service.setEnabled(true, sessions: [first, second], events: [])

        service.setEnabled(false, sessions: [first, second], events: [])
        await waitUntil { self.provider.ended.count == 2 }

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(provider.ended.count, 2)
        XCTAssertTrue(provider.ended.allSatisfy(\.immediately))
    }

    func testImmediatelyReenablingDoesNotReuseAnActivityScheduledForRemoval() async {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])

        service.setEnabled(false, sessions: [session], events: [])
        service.setEnabled(true, sessions: [session], events: [])
        await waitUntil { !self.provider.ended.isEmpty }

        XCTAssertEqual(provider.started.count, 2)
        XCTAssertEqual(provider.activeActivities.count, 1)
        XCTAssertEqual(provider.activeActivities.first?.attributes.sessionID, session.id)
    }

    func testMissingSessionsEndRestoredSystemActivities() async {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])

        service.synchronize(sessions: [], events: [])
        await waitUntil { !self.provider.ended.isEmpty }

        XCTAssertEqual(provider.ended.first?.attributes.sessionID, session.id)
    }

    func testSystemDismissedActivityRequiresExplicitRestart() throws {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])
        let firstActivity = try XCTUnwrap(provider.started.first)

        provider.simulateSystemDismissal(id: firstActivity.id)
        service.synchronize(sessions: [session], events: [])

        XCTAssertEqual(provider.started.count, 1)
        XCTAssertTrue(provider.activeActivities.isEmpty)
        XCTAssertEqual(service.monitoredSessionCount, 1)
        XCTAssertEqual(service.activeActivityCount, 0)
        XCTAssertEqual(service.dismissedActivityCount, 1)

        service.restartDismissedActivities(sessions: [session], events: [])

        XCTAssertEqual(provider.started.count, 2)
        XCTAssertNotEqual(provider.started.last?.id, firstActivity.id)
        XCTAssertEqual(provider.activeActivities.count, 1)
        XCTAssertEqual(service.activeActivityCount, 1)
        XCTAssertEqual(service.dismissedActivityCount, 0)
    }

    func testLiveActivityStatusCountsTrackWaitingActiveAndDisabledStates() async {
        let service = makeService()

        service.setEnabled(true, sessions: [], events: [])
        XCTAssertEqual(service.monitoredSessionCount, 0)
        XCTAssertEqual(service.activeActivityCount, 0)

        let session = makeSession()
        service.synchronize(sessions: [session], events: [])
        XCTAssertEqual(service.monitoredSessionCount, 1)
        XCTAssertEqual(service.activeActivityCount, 1)

        service.setEnabled(false, sessions: [session], events: [])
        await waitUntil { !self.provider.ended.isEmpty }
        XCTAssertEqual(service.activeActivityCount, 0)
        XCTAssertEqual(service.dismissedActivityCount, 0)
    }

    func testExistingSystemActivitiesAreReusedAfterAppRestart() {
        let firstService = makeService()
        let session = makeSession()
        firstService.setEnabled(true, sessions: [session], events: [])
        let restoredService = makeService()

        restoredService.synchronize(sessions: [session], events: [])

        XCTAssertEqual(provider.started.count, 1)
    }

    func testSystemPermissionRevocationEndsExistingActivityAndDisablesPreference() async {
        let service = makeService()
        let session = makeSession()
        service.setEnabled(true, sessions: [session], events: [])
        provider.areActivitiesEnabled = false

        service.synchronize(sessions: [session], events: [])
        await waitUntil { !self.provider.ended.isEmpty }

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.areActivitiesAvailable)
        XCTAssertNotNil(service.presentedError)
    }

    func testPreferencesPersistAcrossServiceRestarts() {
        let service = makeService()
        service.setEnabled(true, sessions: [], events: [])
        service.setShowsServerNames(true, sessions: [], events: [])

        let restored = makeService()

        XCTAssertTrue(restored.isEnabled)
        XCTAssertTrue(restored.showsServerNames)
    }

    func testWidgetDeepLinkTargetsOnlyTheAuthenticatedSessionAndEvent() throws {
        let sessionID = UUID()
        let eventID = UUID()
        let attributes = AgentLiveActivityAttributes(sessionID: sessionID, startedAt: Date())
        let state = AgentLiveActivityAttributes.ContentState(
            status: .approvalRequested,
            displayName: "Coding Agent",
            tmuxSession: nil,
            attentionCount: 1,
            latestEventID: eventID,
            updatedAt: Date(),
            detailsAreHidden: true
        )

        let url = try XCTUnwrap(attributes.deepLink(for: state))

        XCTAssertEqual(AgentDeepLink(url: url), .session(sessionID: sessionID, eventID: eventID))
        XCTAssertFalse(url.absoluteString.contains("command="))
    }

    func testEventCenterCreatesUpdatesAndEndsActivitiesWithManagedSession() async throws {
        let service = makeService()
        let center = AgentEventCenter(
            persistence: AgentEventPersistenceStore(defaults: defaults),
            liveActivities: service,
            defaults: defaults
        )
        let manager = SessionManager(
            persistenceStore: SessionPersistenceStore(defaults: defaults),
            agentEventCenter: center
        )
        center.setLiveActivitiesEnabled(true)
        let session = try XCTUnwrap(manager.createSession(for: makeServer()))

        XCTAssertEqual(provider.started.count, 1)

        _ = center.ingest(
            AgentEventEnvelope(kind: .approvalRequested, title: "Approval needed"),
            from: session
        )
        await waitUntil { !self.provider.updated.isEmpty }

        XCTAssertEqual(provider.updated.last?.state.status, .approvalRequested)

        await manager.closeSession(id: session.id)
        await waitUntil { !self.provider.ended.isEmpty }

        XCTAssertEqual(provider.ended.first?.attributes.sessionID, session.id)
    }

    func testCompanionEventsUpdateOnlyTheMatchedSessionActivity() async throws {
        let service = makeService()
        let center = AgentEventCenter(
            persistence: AgentEventPersistenceStore(defaults: defaults),
            liveActivities: service,
            defaults: defaults
        )
        let manager = SessionManager(
            persistenceStore: SessionPersistenceStore(defaults: defaults),
            agentEventCenter: center
        )
        center.setLiveActivitiesEnabled(true)
        let first = try XCTUnwrap(manager.createSession(for: makeServer(name: "First")))
        let second = try XCTUnwrap(manager.createSession(for: makeServer(name: "Second")))

        _ = center.ingestCompanion(AgentEventEnvelope(
            kind: .needsAttention,
            title: "Review requested",
            sessionID: second.id
        ))
        await waitUntil { !self.provider.updated.isEmpty }

        XCTAssertEqual(provider.updated.last?.attributes.sessionID, second.id)
        XCTAssertEqual(provider.updated.last?.state.status, .needsAttention)
        XCTAssertNotEqual(provider.updated.last?.attributes.sessionID, first.id)
    }

    func testAppDeclaresLiveActivitySupportAndEmbedsWidgetExtension() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool, true)
        let extensionsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = extensionsURL.appendingPathComponent("HoshiLiveActivity.appex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: widget.path))
    }

    func testSystemProviderCreatesAndEndsLiveActivityOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        // ActivityKit presentation is covered by the physical-device branch.
        #else
        let systemProvider = SystemAgentLiveActivityProvider()
        guard systemProvider.areActivitiesEnabled else {
            throw XCTSkip("Live Activities are disabled for Hoshi on this device.")
        }

        let attributes = AgentLiveActivityAttributes(sessionID: UUID(), startedAt: Date())
        let state = AgentLiveActivityAttributes.ContentState(
            status: .running,
            displayName: "Coding Agent",
            tmuxSession: nil,
            attentionCount: 0,
            latestEventID: nil,
            updatedAt: Date(),
            detailsAreHidden: true
        )
        let activityID = try systemProvider.start(attributes: attributes, state: state)

        XCTAssertTrue(systemProvider.activeActivities.contains { $0.id == activityID })

        await systemProvider.end(id: activityID, state: state, immediately: true)
        for _ in 0..<100 {
            if !systemProvider.activeActivities.contains(where: { $0.id == activityID }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The test Live Activity did not end within five seconds.")
        #endif
    }

    private func makeService() -> AgentLiveActivityService {
        AgentLiveActivityService(
            provider: provider,
            defaults: defaults,
            isAppLockEnabled: { [weak self] in self?.appLockEnabled ?? false }
        )
    }

    private func makeServer(name: String = "Agents") -> Server {
        Server(name: name, hostname: "agents.example.com", username: "developer")
    }

    private func makeSession(name: String = "Agents", tmux: String? = nil) -> ManagedSession {
        ManagedSession(server: makeServer(name: name), tmuxSession: tmux)
    }

    private func makeEvent(
        for session: ManagedSession,
        kind: AgentEventKind,
        title: String,
        message: String? = nil
    ) -> AgentInboxEvent {
        AgentInboxEvent(
            id: UUID(),
            kind: kind,
            title: title,
            message: message,
            createdAt: Date(),
            serverID: session.serverID,
            sessionID: session.id,
            serverName: session.serverName,
            hostname: session.server.hostname,
            tmuxSession: session.tmuxSession,
            origin: .terminal,
            readAt: nil
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class MockAgentLiveActivityProvider: AgentLiveActivityProviding {
    struct EndedActivity {
        let attributes: AgentLiveActivityAttributes
        let state: AgentLiveActivityAttributes.ContentState
        let immediately: Bool
    }

    var areActivitiesEnabled = true
    private(set) var started: [AgentLiveActivityRecord] = []
    private(set) var updated: [AgentLiveActivityRecord] = []
    private(set) var ended: [EndedActivity] = []
    private var records: [String: AgentLiveActivityRecord] = [:]

    var activeActivities: [AgentLiveActivityRecord] { Array(records.values) }

    func start(
        attributes: AgentLiveActivityAttributes,
        state: AgentLiveActivityAttributes.ContentState
    ) throws -> String {
        let id = UUID().uuidString
        let record = AgentLiveActivityRecord(id: id, attributes: attributes, state: state)
        records[id] = record
        started.append(record)
        return id
    }

    func update(id: String, state: AgentLiveActivityAttributes.ContentState) async {
        guard let current = records[id] else { return }
        let updatedRecord = AgentLiveActivityRecord(id: id, attributes: current.attributes, state: state)
        records[id] = updatedRecord
        updated.append(updatedRecord)
    }

    func end(id: String, state: AgentLiveActivityAttributes.ContentState, immediately: Bool) async {
        guard let current = records.removeValue(forKey: id) else { return }
        ended.append(EndedActivity(attributes: current.attributes, state: state, immediately: immediately))
    }

    func simulateSystemDismissal(id: String) {
        records.removeValue(forKey: id)
    }
}
