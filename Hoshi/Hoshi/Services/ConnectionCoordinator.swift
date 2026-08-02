import Foundation
import Citadel

enum ConnectionPhase: String, Sendable {
    case sshBootstrap
    case moshDetection
    case tmuxDiscovery
    case moshStartup
    case udpConnection
    case sshFallback

    var statusText: String {
        switch self {
        case .sshBootstrap: "Connecting and verifying SSH host..."
        case .moshDetection: "Checking for mosh-server..."
        case .tmuxDiscovery: "Checking for tmux sessions..."
        case .moshStartup: "Starting mosh-server..."
        case .udpConnection: "Establishing the Mosh UDP connection..."
        case .sshFallback: "Mosh unavailable; falling back to SSH..."
        }
    }
}

struct ConnectionTimeouts: Equatable, Sendable {
    let sshBootstrap: TimeInterval
    let remoteCommand: TimeInterval
    let udpConnection: TimeInterval

    static let `default` = ConnectionTimeouts(
        sshBootstrap: 20,
        remoteCommand: 15,
        udpConnection: 8
    )
}

enum ConnectionCoordinatorError: LocalizedError, Equatable {
    case timedOut(phase: ConnectionPhase, seconds: TimeInterval)
    case bootstrapUnavailable
    case invalidMoshPortRange(String)
    case moshUnavailable
    case transportFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let phase, let seconds):
            return "\(phase.statusText) timed out after \(Int(seconds.rounded())) seconds."
        case .bootstrapUnavailable:
            return "The verified SSH bootstrap is no longer available. Reconnect and try again."
        case .invalidMoshPortRange(let value):
            return "Invalid Mosh UDP port range '\(value)'. Use a port or a range such as 60000:61000."
        case .moshUnavailable:
            return "mosh-server is not available on this host."
        case .transportFailed(let message):
            return message
        }
    }
}

enum ConnectionCoordinatorOutcome {
    case connected
    case awaitingTmuxChoice([TmuxSessionInfo])
    case moshInstallationRequired(RemotePackageManager?)
    case cancelled
}

enum ConnectionDeadline {
    @MainActor
    static func run<Value: Sendable>(
        timeout: TimeInterval,
        phase: ConnectionPhase,
        onTimeout: (@MainActor @Sendable () -> Void)? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                try Task.checkCancellation()
                await onTimeout?()
                throw ConnectionCoordinatorError.timedOut(phase: phase, seconds: timeout)
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}

/// Coordinates one verified SSH bootstrap and then selects SSH or Mosh transport.
@MainActor
final class ConnectionCoordinator {
    private let timeouts: ConnectionTimeouts
    private(set) var sshSession: SSHSession?
    private(set) var moshSession: MoshSession?
    private(set) var activeTransport: ConnectionTransport?
    private(set) var detectedTmuxSessions: [TmuxSessionInfo] = []
    private(set) var fallbackError: (any Error)?
    private var server: Server?
    private var password: String?
    private var keyTag: String?
    private var wasCancelled = false

    var onPhaseChanged: ((ConnectionPhase) -> Void)?
    var onTransportFallback: ((any Error) -> Void)?

    init(timeouts: ConnectionTimeouts = .default) {
        self.timeouts = timeouts
    }

    func prepare(
        server: Server,
        password: String?,
        keyTag: String?
    ) async throws -> ConnectionCoordinatorOutcome {
        self.server = server
        self.password = password
        self.keyTag = keyTag
        wasCancelled = false
        fallbackError = nil

        if server.transportPolicy != .ssh,
           let range = server.moshUDPPortRange,
           !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           MoshPortRange(range) == nil {
            throw ConnectionCoordinatorError.invalidMoshPortRange(range)
        }

        let candidates = server.transportPolicy.candidateTransports
        var moshFailure: (any Error)?
        for (index, transport) in candidates.enumerated() {
            try checkCancellation()

            do {
                let outcome: ConnectionCoordinatorOutcome
                switch transport {
                case .ssh:
                    outcome = try await prepareSSH()
                case .mosh:
                    outcome = try await prepareMosh()
                }

                if case .moshInstallationRequired = outcome,
                   server.transportPolicy == .auto,
                   index + 1 < candidates.count {
                    recordTransportFallback(ConnectionCoordinatorError.moshUnavailable)
                    if let outcome = try await transitionToSSHFallback() {
                        return outcome
                    }
                    return try await prepareMultiplexer()
                }
                return outcome
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SSHHostKeyTrustError {
                throw error
            } catch {
                guard transport == .mosh,
                      server.transportPolicy == .auto,
                      index + 1 < candidates.count,
                      shouldFallback(after: error) else {
                    if transport == .ssh, let moshFailure {
                        throw ConnectionFallbackError(moshError: moshFailure, sshError: error)
                    }
                    throw error
                }

                moshFailure = error
                recordTransportFallback(error)
                if moshSession?.bootstrapClient != nil {
                    do {
                        if let outcome = try await transitionToSSHFallback() {
                            return outcome
                        }
                        return try await prepareMultiplexer()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as SSHHostKeyTrustError {
                        throw error
                    } catch {
                        throw ConnectionFallbackError(moshError: moshFailure ?? error, sshError: error)
                    }
                }

                await moshSession?.disconnect()
                moshSession = nil
                onPhaseChanged?(.sshFallback)
            }
        }

        throw ConnectionCoordinatorError.transportFailed("No supported connection transport is available.")
    }

    func completeTmuxChoice(_ choice: TmuxChoice) async throws -> ConnectionCoordinatorOutcome {
        try checkCancellation()
        let command: String?
        switch choice {
        case .cancel:
            await cancel()
            return .cancelled
        case .attach(let session):
            command = TmuxDetectionService.attachCommand(sessionName: session.name)
        case .newSession:
            command = TmuxDetectionService.newSessionCommand()
        case .newNamedSession(let name):
            command = TmuxDetectionService.newSessionCommand(sessionName: name)
        case .skip:
            command = nil
        }

        do {
            return try await startTransport(command: command)
        } catch {
            let moshError = error
            guard server?.transportPolicy == .auto,
                  activeTransport == .mosh,
                  shouldFallback(after: error) else {
                throw error
            }

            recordTransportFallback(moshError)
            do {
                if let outcome = try await transitionToSSHFallback() {
                    if case .connected = outcome {
                        return outcome
                    }
                }
                return try await startTransport(command: command)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SSHHostKeyTrustError {
                throw error
            } catch {
                throw ConnectionFallbackError(moshError: moshError, sshError: error)
            }
        }
    }

    func finishMoshInstallation(using packageManager: RemotePackageManager) async throws -> ConnectionCoordinatorOutcome {
        guard let moshSession else { throw ConnectionCoordinatorError.bootstrapUnavailable }
        try await ConnectionDeadline.run(
            timeout: max(90, timeouts.remoteCommand * 6),
            phase: .moshStartup
        ) {
            try await moshSession.installServer(
                using: packageManager,
                password: self.password,
                privateKeyTag: self.keyTag
            )
        }
        return try await prepareMultiplexer()
    }

    func refreshTmuxSessions() async throws -> [TmuxSessionInfo] {
        guard let client = sshSession?.client ?? moshSession?.bootstrapClient else {
            throw ConnectionCoordinatorError.bootstrapUnavailable
        }

        let service = TmuxDetectionService(client: client)
        let sessions = try await ConnectionDeadline.run(
            timeout: timeouts.remoteCommand,
            phase: .tmuxDiscovery
        ) {
            try await service.listSessions()
        }
        detectedTmuxSessions = sessions
        return sessions
    }

    func fallBackToSSH() async throws -> ConnectionCoordinatorOutcome {
        recordTransportFallback(ConnectionCoordinatorError.moshUnavailable)
        if let outcome = try await transitionToSSHFallback() {
            return outcome
        }
        return try await prepareMultiplexer()
    }

    func cancel() async {
        wasCancelled = true
        await sshSession?.disconnect()
        await moshSession?.disconnect()
        sshSession = nil
        moshSession = nil
        activeTransport = nil
        detectedTmuxSessions = []
    }

    private func recordTransportFallback(_ error: any Error) {
        guard fallbackError == nil else { return }
        fallbackError = error
        onTransportFallback?(error)
    }

    private func prepareSSH() async throws -> ConnectionCoordinatorOutcome {
        guard let server else { throw ConnectionCoordinatorError.bootstrapUnavailable }
        onPhaseChanged?(.sshBootstrap)
        let session = SSHSession(server: server)
        sshSession = session
        moshSession = nil
        activeTransport = .ssh

        try await ConnectionDeadline.run(timeout: timeouts.sshBootstrap, phase: .sshBootstrap) {
            await session.connectOnly(password: self.password, privateKeyTag: self.keyTag)
            if let identity = session.untrustedHostIdentity {
                throw SSHHostKeyTrustError.untrusted(identity)
            }
            if case .error(let message) = session.connectionState {
                throw session.connectionError ?? ConnectionCoordinatorError.transportFailed(message)
            }
            try Task.checkCancellation()
        }

        return try await prepareMultiplexer()
    }

    private func prepareMosh() async throws -> ConnectionCoordinatorOutcome {
        guard let server else { throw ConnectionCoordinatorError.bootstrapUnavailable }
        onPhaseChanged?(.sshBootstrap)
        let session = MoshSession(server: server)
        moshSession = session
        sshSession = nil
        activeTransport = .mosh

        let status = try await ConnectionDeadline.run(
            timeout: timeouts.sshBootstrap + timeouts.remoteCommand,
            phase: .moshDetection
        ) {
            try await session.prepareBootstrap(password: self.password, privateKeyTag: self.keyTag)
        }

        switch status {
        case .available:
            return try await prepareMultiplexer()
        case .notFound(let packageManager):
            return .moshInstallationRequired(packageManager)
        case .notFoundNoPackageManager:
            return .moshInstallationRequired(nil)
        }
    }

    private func prepareMultiplexer() async throws -> ConnectionCoordinatorOutcome {
        guard let server else { throw ConnectionCoordinatorError.bootstrapUnavailable }
        try checkCancellation()

        if server.tmuxPolicy == .rawShell {
            return try await startTransport(command: nil)
        }

        guard let client = sshSession?.client ?? moshSession?.bootstrapClient else {
            return try await startTransport(command: nil)
        }

        onPhaseChanged?(.tmuxDiscovery)
        let tmuxService = TmuxDetectionService(client: client)
        let available: Bool
        let sessions: [TmuxSessionInfo]

        do {
            available = try await ConnectionDeadline.run(
                timeout: timeouts.remoteCommand,
                phase: .tmuxDiscovery
            ) {
                try await tmuxService.isTmuxAvailable()
            }

            if available {
                sessions = try await ConnectionDeadline.run(
                    timeout: timeouts.remoteCommand,
                    phase: .tmuxDiscovery
                ) {
                    try await tmuxService.listSessions()
                }
            } else {
                sessions = []
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A missing or inaccessible tmux server must not prevent a usable shell.
            return try await startTransport(command: nil)
        }

        guard available else {
            return try await startTransport(command: nil)
        }

        detectedTmuxSessions = sessions
        if server.tmuxPolicy == .autoAttachLast,
           let savedSession = server.tmuxSession,
           sessions.contains(where: { $0.name == savedSession }) {
            return try await startTransport(
                command: TmuxDetectionService.attachCommand(sessionName: savedSession)
            )
        }

        return .awaitingTmuxChoice(sessions)
    }

    private func startTransport(command: String?) async throws -> ConnectionCoordinatorOutcome {
        try checkCancellation()

        if let sshSession {
            sshSession.initialCommand = command
            await sshSession.openTerminal()
            return .connected
        }

        guard let moshSession else {
            throw ConnectionCoordinatorError.bootstrapUnavailable
        }

        onPhaseChanged?(.moshStartup)
        try await ConnectionDeadline.run(
            timeout: timeouts.remoteCommand + timeouts.udpConnection,
            phase: .moshStartup
        ) {
            try await moshSession.startPreparedConnection(
                initialCommand: command,
                udpTimeout: self.timeouts.udpConnection
            )
        }
        return .connected
    }

    private func transitionToSSHFallback() async throws -> ConnectionCoordinatorOutcome? {
        guard let server else { throw ConnectionCoordinatorError.bootstrapUnavailable }
        onPhaseChanged?(.sshFallback)

        if let moshSession,
           let client = moshSession.takeBootstrapClient() {
            await moshSession.disconnect()
            self.moshSession = nil

            let sshSession = SSHSession(server: server)
            sshSession.adoptBootstrapClient(client, password: password, privateKeyTag: keyTag)
            self.sshSession = sshSession
            activeTransport = .ssh
            return nil
        }

        await moshSession?.disconnect()
        moshSession = nil
        return try await prepareSSH()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if wasCancelled {
            throw CancellationError()
        }
    }

    static func shouldFallback(after error: any Error) -> Bool {
        if !ErrorPresentation.shouldPresent(error) || error is SSHHostKeyTrustError {
            return false
        }
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return false
            case .channelCreationFailed:
                break
            }
        }
        if error is AuthenticationFailed {
            return false
        }
        if let sshError = error as? SSHConnectionError,
           case .authenticationFailed = sshError {
            return false
        }
        if let sshError = error as? SSHConnectionError {
            switch sshError {
            case .passwordNotFound, .keyNotFound:
                return false
            default:
                break
            }
        }
        if let coordinatorError = error as? ConnectionCoordinatorError,
           case .invalidMoshPortRange = coordinatorError {
            return false
        }
        return true
    }

    private func shouldFallback(after error: any Error) -> Bool {
        Self.shouldFallback(after: error)
    }
}
