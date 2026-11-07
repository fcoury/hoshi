import Foundation
import UIKit

/// Turns changes between two Herdr inventories into Hoshi agent events.
///
/// - A higher `completion_seq` means the agent finished a turn → `completed`.
/// - Entering `blocked` means Herdr recognized an approval or question
///   prompt → `needsAttention`. Hoshi never answers it automatically.
///
/// Agents first seen in `current` only establish a baseline, so connecting
/// never replays old completions.
enum HerdrAgentChangeDetector {
    struct Key: Hashable {
        let session: String
        let paneID: String
    }

    static func snapshot(of inventory: HerdrInventory) -> [Key: HerdrAgent] {
        var snapshot: [Key: HerdrAgent] = [:]
        for session in inventory.sessions {
            for agent in session.agents {
                snapshot[Key(session: session.id, paneID: agent.paneID)] = agent
            }
        }
        return snapshot
    }

    static func events(
        previous: [Key: HerdrAgent],
        current: HerdrInventory,
        hostname: String?
    ) -> [AgentEventEnvelope] {
        var events: [AgentEventEnvelope] = []
        for session in current.sessions {
            for agent in session.agents {
                guard let before = previous[Key(session: session.id, paneID: agent.paneID)] else {
                    continue
                }

                if agent.status == .blocked, before.status != .blocked {
                    events.append(envelope(
                        kind: .needsAttention,
                        title: "\(name(of: agent, in: session)) needs input",
                        agent: agent,
                        session: session,
                        hostname: hostname
                    ))
                } else if agent.completionSeq > before.completionSeq {
                    events.append(envelope(
                        kind: .completed,
                        title: "\(name(of: agent, in: session)) finished",
                        agent: agent,
                        session: session,
                        hostname: hostname
                    ))
                }
            }
        }
        return events
    }

    /// "Claude", or "Claude on build-box" for an agent on a saved machine.
    private static func name(of agent: HerdrAgent, in session: HerdrSessionInfo) -> String {
        session.machine.map { "\(agent.displayName) on \($0.label)" } ?? agent.displayName
    }

    private static func envelope(
        kind: AgentEventKind,
        title: String,
        agent: HerdrAgent,
        session: HerdrSessionInfo,
        hostname: String?
    ) -> AgentEventEnvelope {
        let location = session.machine.map { "via Herdr machine \($0.label)" } ?? "Herdr session \(session.name)"
        let context = [agent.title, agent.directoryName.map { "in \($0)" }, location]
            .compactMap { $0 }
            .joined(separator: " · ")
        return AgentEventEnvelope(
            kind: kind,
            title: String(title.prefix(200)),
            message: String(context.prefix(1_000)),
            timestamp: Date(),
            hostname: hostname.map { String($0.prefix(255)) },
            herdrTarget: session.target(for: agent)
        )
    }
}

/// Ensures only one monitor per host and Herdr view reports events, so two
/// Hoshi sessions on the same Herdr session do not duplicate every notification. Other monitors
/// keep tracking state and take over when the reporting one stops.
@MainActor
enum HerdrEventReporterRegistry {
    private static var owners: [String: ObjectIdentifier] = [:]

    static func claim(_ key: String, for owner: AnyObject) -> Bool {
        let id = ObjectIdentifier(owner)
        if let current = owners[key] { return current == id }
        owners[key] = id
        return true
    }

    static func release(_ key: String, for owner: AnyObject) {
        if owners[key] == ObjectIdentifier(owner) {
            owners[key] = nil
        }
    }
}

/// Polls Herdr over the session's verified SSH connection while Hoshi is in
/// the foreground and reports agent changes as `AgentEventEnvelope`s.
///
/// iOS suspends networking in the background, so like the self-hosted
/// companion this does not claim background delivery. Changes that happened
/// while suspended are reported on the first poll after returning.
@MainActor
final class HerdrAgentMonitor {
    typealias CommandRunner = @MainActor (String) async throws -> String

    private let runner: CommandRunner
    private let hostname: String?
    private let hostKey: String?
    private let interval: Duration
    private let onEvent: @MainActor (AgentEventEnvelope) -> Void
    private let onInventory: @MainActor (HerdrInventory) -> Void
    /// What the terminal shows from Herdr right now. Only those agents raise
    /// events: a plain shell on a host running Herdr stays quiet.
    private let attachment: @MainActor () -> HerdrAttachment?
    private var claimedKey: String?

    private var task: Task<Void, Never>?
    private var previous: [HerdrAgentChangeDetector.Key: HerdrAgent]?
    private var isForeground = true
    private var observers: [NSObjectProtocol] = []

    init(
        hostname: String?,
        hostKey: String? = nil,
        interval: Duration = .seconds(5),
        runner: @escaping CommandRunner,
        attachment: @escaping @MainActor () -> HerdrAttachment?,
        onEvent: @escaping @MainActor (AgentEventEnvelope) -> Void,
        onInventory: @escaping @MainActor (HerdrInventory) -> Void = { _ in }
    ) {
        self.hostname = hostname
        self.hostKey = hostKey
        self.interval = interval
        self.runner = runner
        self.attachment = attachment
        self.onEvent = onEvent
        self.onInventory = onInventory
    }

    /// Seeds the baseline from the inventory found while connecting, so the
    /// first poll can already report changes.
    func start(baseline: HerdrInventory?) {
        guard task == nil else { return }
        previous = baseline.map(HerdrAgentChangeDetector.snapshot(of:))
        observeLifecycle()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        releaseClaim()
    }

    /// Polls immediately, for example after the user changed Herdr's focus.
    func pollNow() async {
        guard let output = try? await runner(HerdrDiscovery.remoteCommand),
              let inventory = HerdrDiscovery.parse(output) else { return }
        process(inventory)
    }

    /// Processes one discovery output. Exposed for tests.
    func process(_ inventory: HerdrInventory) {
        if let attachment = attachment(), claimReporting(for: attachment), let previous {
            for event in HerdrAgentChangeDetector.events(
                previous: previous,
                current: inventory,
                hostname: hostname
            ) where event.herdrTarget.map(attachment.shows) ?? false {
                onEvent(event)
            }
        } else if attachment() == nil {
            releaseClaim()
        }
        previous = HerdrAgentChangeDetector.snapshot(of: inventory)
        onInventory(inventory)
    }

    private func claimReporting(for attachment: HerdrAttachment) -> Bool {
        guard let hostKey else { return true }
        let key = "\(hostKey)#\(attachment.reporterKey)"
        if claimedKey != key { releaseClaim() }
        guard HerdrEventReporterRegistry.claim(key, for: self) else { return false }
        claimedKey = key
        return true
    }

    private func releaseClaim() {
        if let claimedKey { HerdrEventReporterRegistry.release(claimedKey, for: self) }
        claimedKey = nil
    }

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            guard isForeground else { continue }

            do {
                let output = try await runner(HerdrDiscovery.remoteCommand)
                guard !Task.isCancelled, let inventory = HerdrDiscovery.parse(output) else { continue }
                process(inventory)
            } catch {
                // Transient SSH failures keep the baseline; the next poll retries.
                continue
            }
        }
    }

    private func observeLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isForeground = false }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isForeground = true }
            },
        ]
    }
}
