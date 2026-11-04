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
                snapshot[Key(session: session.name, paneID: agent.paneID)] = agent
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
                guard let before = previous[Key(session: session.name, paneID: agent.paneID)] else {
                    continue
                }

                if agent.status == .blocked, before.status != .blocked {
                    events.append(envelope(
                        kind: .needsAttention,
                        title: "\(agent.displayName) needs input",
                        agent: agent,
                        session: session.name,
                        hostname: hostname
                    ))
                } else if agent.completionSeq > before.completionSeq {
                    events.append(envelope(
                        kind: .completed,
                        title: "\(agent.displayName) finished",
                        agent: agent,
                        session: session.name,
                        hostname: hostname
                    ))
                }
            }
        }
        return events
    }

    private static func envelope(
        kind: AgentEventKind,
        title: String,
        agent: HerdrAgent,
        session: String,
        hostname: String?
    ) -> AgentEventEnvelope {
        let context = [agent.title, agent.directoryName.map { "in \($0)" }, "Herdr session \(session)"]
            .compactMap { $0 }
            .joined(separator: " · ")
        return AgentEventEnvelope(
            kind: kind,
            title: String(title.prefix(200)),
            message: String(context.prefix(1_000)),
            timestamp: Date(),
            hostname: hostname.map { String($0.prefix(255)) }
        )
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
    private let interval: Duration
    private let onEvent: @MainActor (AgentEventEnvelope) -> Void
    private let onInventory: @MainActor (HerdrInventory) -> Void

    private var task: Task<Void, Never>?
    private var previous: [HerdrAgentChangeDetector.Key: HerdrAgent]?
    private var isForeground = true
    private var observers: [NSObjectProtocol] = []

    init(
        hostname: String?,
        interval: Duration = .seconds(5),
        runner: @escaping CommandRunner,
        onEvent: @escaping @MainActor (AgentEventEnvelope) -> Void,
        onInventory: @escaping @MainActor (HerdrInventory) -> Void = { _ in }
    ) {
        self.hostname = hostname
        self.interval = interval
        self.runner = runner
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
    }

    /// Processes one discovery output. Exposed for tests.
    func process(_ inventory: HerdrInventory) {
        if let previous {
            for event in HerdrAgentChangeDetector.events(
                previous: previous,
                current: inventory,
                hostname: hostname
            ) {
                onEvent(event)
            }
        }
        previous = HerdrAgentChangeDetector.snapshot(of: inventory)
        onInventory(inventory)
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
