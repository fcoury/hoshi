import ActivityKit
import Foundation

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

    private(set) var isEnabled: Bool
    private(set) var showsServerNames: Bool
    private(set) var presentedError: ErrorPresentation?

    var areActivitiesAvailable: Bool { provider.areActivitiesEnabled }

    init(
        provider: (any AgentLiveActivityProviding)? = nil,
        defaults: UserDefaults = .standard,
        isAppLockEnabled: (@MainActor () -> Bool)? = nil
    ) {
        self.provider = provider ?? SystemAgentLiveActivityProvider()
        self.defaults = defaults
        self.isAppLockEnabled = isAppLockEnabled ?? { AppLockService.shared.isEnabled }
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.showsServerNames = defaults.bool(forKey: Self.showsServerNamesKey)
    }

    func setEnabled(_ enabled: Bool, sessions: [ManagedSession], events: [AgentInboxEvent]) {
        presentedError = nil

        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            endAllActivities()
            return
        }

        guard provider.areActivitiesEnabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            presentError(ErrorMessageFailure(
                message: "Enable Live Activities for Hoshi in iOS Settings."
            ))
            return
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
        guard isEnabled else {
            endAllActivities()
            return
        }

        guard provider.areActivitiesEnabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            endAllActivities()
            presentError(ErrorMessageFailure(
                message: "Live Activities were disabled in iOS Settings."
            ))
            return
        }

        restoreSystemActivities()
        let sessionIDs = Set(sessions.map(\.id))
        for sessionID in Array(activityIDs.keys) where !sessionIDs.contains(sessionID) {
            endSession(id: sessionID)
        }

        for session in sessions {
            synchronize(session: session, events: events)
        }
    }

    func endSession(id: UUID) {
        updateTasks[id]?.cancel()
        updateTasks[id] = nil
        guard let activityID = activityIDs.removeValue(forKey: id),
              let state = activityStates.removeValue(forKey: id) else { return }

        endingActivityIDs.insert(activityID)
        Task { [weak self, provider] in
            await provider.end(id: activityID, state: state, immediately: true)
            self?.endingActivityIDs.remove(activityID)
        }
    }

    private func synchronize(session: ManagedSession, events: [AgentInboxEvent]) {
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
            return
        }

        let attributes = AgentLiveActivityAttributes(sessionID: session.id, startedAt: session.createdAt)
        do {
            let activityID = try provider.start(attributes: attributes, state: state)
            activityIDs[session.id] = activityID
            activityStates[session.id] = state
        } catch {
            presentError(error)
        }
    }

    private func restoreSystemActivities() {
        for activity in provider.activeActivities {
            let sessionID = activity.attributes.sessionID
            guard !endingActivityIDs.contains(activity.id),
                  activityIDs[sessionID] == nil else { continue }
            activityIDs[sessionID] = activity.id
            activityStates[sessionID] = activity.state
        }
    }

    private func endAllActivities() {
        restoreSystemActivities()
        for sessionID in Array(activityIDs.keys) {
            endSession(id: sessionID)
        }
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
