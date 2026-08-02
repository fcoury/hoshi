import ActivityKit
import Foundation
import OSLog

@MainActor
struct AgentLiveActivityRecord {
    let id: String
    let attributes: AgentLiveActivityAttributes
    let state: AgentLiveActivityAttributes.ContentState
}

@MainActor
protocol AgentLiveActivityProviding: AnyObject {
    var areActivitiesEnabled: Bool { get }
    var activeActivities: [AgentLiveActivityRecord] { get }

    func start(
        attributes: AgentLiveActivityAttributes,
        state: AgentLiveActivityAttributes.ContentState
    ) throws -> String
    func update(id: String, state: AgentLiveActivityAttributes.ContentState) async
    func end(id: String, state: AgentLiveActivityAttributes.ContentState, immediately: Bool) async
}

@MainActor
final class SystemAgentLiveActivityProvider: AgentLiveActivityProviding {
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var activeActivities: [AgentLiveActivityRecord] {
        Activity<AgentLiveActivityAttributes>.activities.compactMap { activity in
            switch activity.activityState {
            case .active, .stale:
                AgentLiveActivityRecord(
                    id: activity.id,
                    attributes: activity.attributes,
                    state: activity.content.state
                )
            default:
                nil
            }
        }
    }

    func start(
        attributes: AgentLiveActivityAttributes,
        state: AgentLiveActivityAttributes.ContentState
    ) throws -> String {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(4 * 60 * 60))
        let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        return activity.id
    }

    func update(id: String, state: AgentLiveActivityAttributes.ContentState) async {
        guard let activity = Activity<AgentLiveActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(4 * 60 * 60))
        )
    }

    func end(id: String, state: AgentLiveActivityAttributes.ContentState, immediately: Bool) async {
        guard let activity = Activity<AgentLiveActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .after(Date().addingTimeInterval(60))
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
    }
}

@MainActor
protocol AgentLiveActivityManaging: AnyObject {
    var isEnabled: Bool { get }
    var showsServerNames: Bool { get }

    func setEnabled(_ enabled: Bool, sessions: [ManagedSession], events: [AgentInboxEvent])
    func setShowsServerNames(_ enabled: Bool, sessions: [ManagedSession], events: [AgentInboxEvent])
    func synchronize(sessions: [ManagedSession], events: [AgentInboxEvent])
    func restartDismissedActivities(sessions: [ManagedSession], events: [AgentInboxEvent])
    func endSession(id: UUID)
}

@MainActor @Observable
final class AgentLiveActivityService: AgentLiveActivityManaging {
    static let shared = AgentLiveActivityService()

    private static let enabledKey = "app.gethoshi.agent-live-activities-enabled"
    private static let showsServerNamesKey = "app.gethoshi.agent-live-activity-server-names"

    @ObservationIgnored private let provider: any AgentLiveActivityProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isAppLockEnabled: @MainActor () -> Bool
    @ObservationIgnored private var activityIDs: [UUID: String] = [:]
    @ObservationIgnored private var activityStates: [UUID: AgentLiveActivityAttributes.ContentState] = [:]
    @ObservationIgnored private var endingActivityIDs: Set<String> = []
    @ObservationIgnored private var updateTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissedSessionIDs: Set<UUID> = []
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.gethoshi.ios",
        category: "AgentLiveActivity"
    )

    private(set) var isEnabled: Bool
    private(set) var showsServerNames: Bool
    private(set) var presentedError: ErrorPresentation?
    private(set) var monitoredSessionCount = 0
    private(set) var activeActivityCount = 0
    private(set) var dismissedActivityCount = 0
    private(set) var areActivitiesAvailable: Bool

    init(
        provider: (any AgentLiveActivityProviding)? = nil,
        defaults: UserDefaults = .standard,
        isAppLockEnabled: (@MainActor () -> Bool)? = nil
    ) {
        let resolvedProvider = provider ?? SystemAgentLiveActivityProvider()
        self.provider = resolvedProvider
        self.defaults = defaults
        self.isAppLockEnabled = isAppLockEnabled ?? { AppLockService.shared.isEnabled }
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.showsServerNames = defaults.bool(forKey: Self.showsServerNamesKey)
        self.areActivitiesAvailable = resolvedProvider.areActivitiesEnabled
    }

    func setEnabled(_ enabled: Bool, sessions: [ManagedSession], events: [AgentInboxEvent]) {
        presentedError = nil
        areActivitiesAvailable = provider.areActivitiesEnabled

        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            endAllActivities()
            return
        }

        guard areActivitiesAvailable else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            presentError(ErrorMessageFailure(
                message: "Enable Live Activities for Hoshi in iOS Settings."
            ))
            return
        }

        if !isEnabled {
            dismissedSessionIDs.removeAll()
            dismissedActivityCount = 0
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        synchronize(sessions: sessions, events: events)
    }

    func setShowsServerNames(_ enabled: Bool, sessions: [ManagedSession], events: [AgentInboxEvent]) {
        showsServerNames = enabled
        defaults.set(enabled, forKey: Self.showsServerNamesKey)
        synchronize(sessions: sessions, events: events)
    }

    func synchronize(sessions: [ManagedSession], events: [AgentInboxEvent]) {
        monitoredSessionCount = sessions.count
        areActivitiesAvailable = provider.areActivitiesEnabled

        guard isEnabled else {
            endAllActivities()
            return
        }

        guard areActivitiesAvailable else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            endAllActivities()
            presentError(ErrorMessageFailure(
                message: "Live Activities were disabled in iOS Settings."
            ))
            return
        }

        reconcileSystemActivities()
        let sessionIDs = Set(sessions.map(\.id))
        for sessionID in Array(activityIDs.keys) where !sessionIDs.contains(sessionID) {
            endSession(id: sessionID)
        }

        for session in sessions {
            synchronize(session: session, events: events)
        }
        activeActivityCount = activityIDs.count
    }

    func restartDismissedActivities(sessions: [ManagedSession], events: [AgentInboxEvent]) {
        areActivitiesAvailable = provider.areActivitiesEnabled
        guard isEnabled, areActivitiesAvailable else {
            synchronize(sessions: sessions, events: events)
            return
        }
        dismissedSessionIDs.removeAll()
        dismissedActivityCount = 0
        presentedError = nil
        synchronize(sessions: sessions, events: events)
    }

    func endSession(id: UUID) {
        updateTasks[id]?.cancel()
        updateTasks[id] = nil
        dismissedSessionIDs.remove(id)
        dismissedActivityCount = dismissedSessionIDs.count
        guard let activityID = activityIDs.removeValue(forKey: id) else { return }
        let state = activityStates.removeValue(forKey: id)
            ?? provider.activeActivities.first(where: { $0.id == activityID })?.state
        activeActivityCount = activityIDs.count
        guard let state else {
            logger.warning("Unable to end Live Activity because its content state is unavailable")
            return
        }

        endingActivityIDs.insert(activityID)
        Task { [weak self, provider] in
            await provider.end(id: activityID, state: state, immediately: true)
            self?.endingActivityIDs.remove(activityID)
            self?.logger.info("Ended Live Activity")
        }
    }

    private func synchronize(session: ManagedSession, events: [AgentInboxEvent]) {
        guard !dismissedSessionIDs.contains(session.id) else { return }

        let unread = events.filter { $0.sessionID == session.id && $0.isUnread }
        let event = unread.max {
            if $0.kind.attentionPriority == $1.kind.attentionPriority {
                return $0.createdAt < $1.createdAt
            }
            return $0.kind.attentionPriority < $1.kind.attentionPriority
        }

        let hidden = !showsServerNames || isAppLockEnabled()
        let state = AgentLiveActivityAttributes.ContentState(
            status: status(for: event),
            displayName: hidden ? "Coding Agent" : Self.safeDisplayText(session.serverName),
            tmuxSession: hidden ? nil : session.tmuxSession.map(Self.safeDisplayText),
            attentionCount: min(unread.count, 99),
            latestEventID: event?.id,
            updatedAt: event?.createdAt ?? session.createdAt,
            detailsAreHidden: hidden
        )

        if let activityID = activityIDs[session.id] {
            guard activityStates[session.id] != state else { return }
            activityStates[session.id] = state
            updateTasks[session.id]?.cancel()
            updateTasks[session.id] = Task { [provider] in
                guard !Task.isCancelled else { return }
                await provider.update(id: activityID, state: state)
            }
            logger.debug("Scheduled Live Activity update")
            return
        }

        let attributes = AgentLiveActivityAttributes(sessionID: session.id, startedAt: session.createdAt)
        do {
            let activityID = try provider.start(attributes: attributes, state: state)
            activityIDs[session.id] = activityID
            activityStates[session.id] = state
            activeActivityCount = activityIDs.count
            logger.info("Started Live Activity")
        } catch {
            let nsError = error as NSError
            logger.error(
                "Failed to start Live Activity (domain: \(nsError.domain, privacy: .public), code: \(nsError.code))"
            )
            presentError(error)
        }
    }

    /// Treat ActivityKit as the source of truth. An activity can disappear while
    /// Hoshi is suspended (for example, after a user dismissal or a system
    /// invalidation), leaving an otherwise-valid in-memory identifier behind.
    /// Removing stale identifiers here prevents updates from being sent to a
    /// nonexistent activity. The session remains suppressed until the person
    /// explicitly restarts Live Activities, respecting an intentional dismissal.
    private func reconcileSystemActivities() {
        let systemActivities = provider.activeActivities
        let activeIDs = Set(systemActivities.map(\.id))

        let staleSessionIDs = activityIDs.compactMap { sessionID, activityID in
            !activeIDs.contains(activityID) && !endingActivityIDs.contains(activityID) ? sessionID : nil
        }
        for sessionID in staleSessionIDs {
            updateTasks[sessionID]?.cancel()
            updateTasks[sessionID] = nil
            activityIDs.removeValue(forKey: sessionID)
            activityStates.removeValue(forKey: sessionID)
            dismissedSessionIDs.insert(sessionID)
            logger.notice("Observed dismissed or invalidated Live Activity")
        }

        for activity in systemActivities {
            let sessionID = activity.attributes.sessionID
            guard !endingActivityIDs.contains(activity.id),
                  activityIDs[sessionID] == nil else { continue }
            dismissedSessionIDs.remove(sessionID)
            activityIDs[sessionID] = activity.id
            activityStates[sessionID] = activity.state
        }
        activeActivityCount = activityIDs.count
        dismissedActivityCount = dismissedSessionIDs.count
    }

    private func endAllActivities() {
        reconcileSystemActivities()
        for sessionID in Array(activityIDs.keys) {
            endSession(id: sessionID)
        }
        dismissedSessionIDs.removeAll()
        dismissedActivityCount = 0
    }

    private func status(for event: AgentInboxEvent?) -> AgentLiveActivityAttributes.Status {
        switch event?.kind {
        case .completed: .completed
        case .needsAttention: .needsAttention
        case .approvalRequested: .approvalRequested
        case nil: .running
        }
    }

    private static func safeDisplayText(_ text: String) -> String {
        let filtered = String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Coding Agent" : trimmed).prefix(64))
    }

    private func presentError(_ error: any Error) {
        presentedError = ErrorPresentation.classify(
            error,
            context: ErrorContext(operation: .liveActivities)
        )
    }
}
