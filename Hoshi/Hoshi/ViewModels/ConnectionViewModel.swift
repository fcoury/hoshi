import Foundation
import SwiftUI
import Combine

@MainActor
@Observable
final class ConnectionViewModel {
    // Active session — either SSH or Mosh
    var sshSession: SSHSession? {
        didSet { bindSessionState() }
    }
    var moshSession: MoshSession? {
        didSet { bindSessionState() }
    }
    var isConnecting = false
    var errorMessage: String?
    var showError = false
    var onAgentEvent: (@MainActor (AgentEventEnvelope) -> Void)? {
        didSet { bindAgentEvents() }
    }

    // Mosh-specific UI state
    var connectionPhase: String = ""
    var showMoshInstallOffer = false
    var detectedPackageManager: RemotePackageManager?

    // tmux session picker state
    var showTmuxPicker = false {
        didSet { bindSessionState() }
    }
    var detectedTmuxSessions: [TmuxSessionInfo] = []

    // Stashed credentials for fallback/install retry
    private var pendingServer: Server?
    private var pendingPassword: String?
    private var pendingKeyTag: String?
    private var pendingHostKeyIdentity: SSHHostKeyIdentity?

    // Bridged state from the active session's @Published connectionState.
    // SSHSession/MoshSession use ObservableObject + @Published (Combine),
    // but this class uses @Observable (Swift Observation). These two systems
    // don't bridge automatically — changes to sshSession.connectionState
    // don't trigger @Observable updates. This stored property is synced via
    // a Combine subscription so SwiftUI sees changes.
    private(set) var currentSessionState: ConnectionState = .disconnected

    // Combine subscription that forwards session state changes
    @ObservationIgnored
    private var sessionStateCancellable: AnyCancellable?
    @ObservationIgnored
    private var coordinator: ConnectionCoordinator?
    @ObservationIgnored
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration: UUID?

    // The active session's connection state — suppress .connected until terminal is open
    var connectionState: ConnectionState {
        if showTmuxPicker { return .connecting }
        return currentSessionState
    }

    // Subscribe to the active session's @Published connectionState and
    // mirror it into currentSessionState so @Observable can track it.
    private func bindSessionState() {
        sessionStateCancellable?.cancel()
        sessionStateCancellable = nil

        if showTmuxPicker {
            currentSessionState = .connecting
        } else if let moshSession {
            currentSessionState = moshSession.connectionState
            sessionStateCancellable = moshSession.$connectionState
                .sink { [weak self] state in
                    self?.currentSessionState = state
                }
        } else if let sshSession {
            currentSessionState = sshSession.connectionState
            sessionStateCancellable = sshSession.$connectionState
                .sink { [weak self] state in
                    self?.currentSessionState = state
                }
        } else {
            currentSessionState = .disconnected
        }
        bindAgentEvents()
    }

    private func bindAgentEvents() {
        sshSession?.onAgentEvent = { [weak self] event in
            self?.onAgentEvent?(event)
        }
        moshSession?.onAgentEvent = { [weak self] event in
            self?.onAgentEvent?(event)
        }
    }

    // Whether a session object exists (even if currently disconnected/reconnecting)
    var hasActiveSession: Bool {
        sshSession != nil || moshSession != nil
    }

    var selectedSSHKeyID: String? {
        pendingKeyTag
    }

    // The active session's output buffer (fallback for plain text mode)
    var outputBuffer: String {
        get {
            if let moshSession { return moshSession.outputBuffer }
            if let sshSession { return sshSession.outputBuffer }
            return ""
        }
        set {
            if moshSession != nil { moshSession?.outputBuffer = newValue }
            else if sshSession != nil { sshSession?.outputBuffer = newValue }
        }
    }

    // Set the raw data callback on the active session for terminal rendering
    func setDataCallback(_ callback: TerminalDataCallback?) {
        sshSession?.onDataReceived = callback
        moshSession?.onDataReceived = callback

        guard let callback else { return }
        let bufferedOutput = moshSession?.consumeBufferedTerminalOutput()
            ?? sshSession?.consumeBufferedTerminalOutput()
            ?? Data()
        if !bufferedOutput.isEmpty {
            callback(Array(bufferedOutput))
        }
    }

    // Send raw keystroke bytes to the active session
    func sendBytes(_ bytes: ArraySlice<UInt8>) async {
        let data = Data(bytes)
        if let moshSession { await moshSession.send(data) }
        else if let sshSession { await sshSession.send(data) }
    }

    // Connect through one verified bootstrap, transport policy, and tmux pipeline.
    func connect(server: Server, password: String?, keyTag: String?) async {
        connectionTask?.cancel()
        let generation = UUID()
        connectionGeneration = generation
        isConnecting = true
        errorMessage = nil
        showError = false
        connectionPhase = ""
        showMoshInstallOffer = false
        detectedTmuxSessions = []

        if server.authMethod == .key {
            guard let keyTag else {
                errorMessage = SSHConnectionError.keyNotFound.localizedDescription
                showError = true
                isConnecting = false
                return
            }
            server.keyID = keyTag
        }

        // Stash credentials for potential fallback
        pendingServer = server
        pendingPassword = password
        pendingKeyTag = keyTag

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnection(
                server: server,
                password: password,
                keyTag: keyTag,
                generation: generation
            )
        }
        connectionTask = task
        await task.value

        if connectionGeneration == generation {
            connectionTask = nil
        }
    }

    // Handle the user's tmux session choice — returns the chosen session name for display
    func completeTmuxChoice(_ choice: TmuxChoice) async -> String? {
        showTmuxPicker = false
        guard let coordinator else { return nil }

        do {
            let outcome = try await coordinator.completeTmuxChoice(choice)
            adoptCoordinatorSessions(coordinator)

            guard case .connected = outcome else { return nil }
            pendingServer?.lastConnected = Date()

            if case .attach(let session) = choice {
                if pendingServer?.tmuxPolicy == .autoAttachLast {
                    pendingServer?.tmuxSession = session.name
                }
                return session.name
            }
            if case .newNamedSession(let name) = choice {
                if pendingServer?.tmuxPolicy == .autoAttachLast {
                    pendingServer?.tmuxSession = name
                }
                return name
            }
            return nil
        } catch {
            presentConnectionError(error)
            return nil
        }
    }

    func refreshTmuxSessions() async {
        guard let coordinator else { return }
        do {
            detectedTmuxSessions = try await coordinator.refreshTmuxSessions()
        } catch {
            errorMessage = "Unable to refresh tmux sessions: \(error.localizedDescription)"
            showError = true
        }
    }

    func cancelConnection() {
        if let pendingHostKeyIdentity,
           HostKeyTrustCoordinator.shared.pendingIdentity == pendingHostKeyIdentity {
            HostKeyTrustCoordinator.shared.resolvePendingIdentity(trusted: false)
        }
        pendingHostKeyIdentity = nil
        connectionGeneration = nil
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
        connectionPhase = ""

        let coordinator = self.coordinator
        self.coordinator = nil
        Task { [weak self] in
            await coordinator?.cancel()
            self?.sshSession = nil
            self?.moshSession = nil
            self?.showTmuxPicker = false
        }
    }

    // Handle app returning to foreground — check session health and reconnect if needed
    func handleSceneActive() {
        if let moshSession {
            // Mosh handles resume natively via UDP, but iOS may have suspended the socket.
            // Force a UDP reconnect to re-establish the path after backgrounding.
            Task {
                await moshSession.handleAppResume()
            }
            return
        }

        if let sshSession {
            // If the SSH session silently died while backgrounded, trigger reconnect.
            // Don't reconnect if the user typed 'exit' — that's an intentional end.
            if sshSession.connectionState == .disconnected && !sshSession.sessionEndedNormally {
                Task {
                    await sshSession.reconnect()
                }
            }
        }
    }

    // Disconnect the current session (user-initiated)
    func disconnect() async {
        if let pendingHostKeyIdentity,
           HostKeyTrustCoordinator.shared.pendingIdentity == pendingHostKeyIdentity {
            HostKeyTrustCoordinator.shared.resolvePendingIdentity(trusted: false)
        }
        connectionGeneration = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let coordinator {
            await coordinator.cancel()
            self.coordinator = nil
        } else {
            await moshSession?.disconnect()
            await sshSession?.disconnect()
        }
        moshSession = nil
        sshSession = nil
        showTmuxPicker = false
        detectedTmuxSessions = []
        pendingServer = nil
        pendingPassword = nil
        pendingKeyTag = nil
        pendingHostKeyIdentity = nil
    }

    // Send data to the active session
    func send(_ data: Data) async {
        if let moshSession { await moshSession.send(data) }
        else if let sshSession { await sshSession.send(data) }
    }

    // Send a string to the active session
    func sendString(_ string: String) async {
        if let moshSession { await moshSession.sendString(string) }
        else if let sshSession { await sshSession.sendString(string) }
    }

    // Resize the active session's terminal
    func resize(cols: Int, rows: Int) async {
        if let moshSession { await moshSession.resize(cols: cols, rows: rows) }
        else if let sshSession { await sshSession.resize(cols: cols, rows: rows) }
    }

    // Called when user accepts mosh-server installation
    func installMoshServer() async {
        guard let coordinator, let pm = detectedPackageManager else { return }
        showMoshInstallOffer = false
        isConnecting = true
        connectionPhase = "Installing mosh-server..."

        do {
            let outcome = try await coordinator.finishMoshInstallation(using: pm)
            adoptCoordinatorSessions(coordinator)
            applyCoordinatorOutcome(outcome)
        } catch {
            presentConnectionError(error)
        }

        isConnecting = false

        if connectionState == .connected {
            pendingServer?.lastConnected = Date()
        }
    }

    // Called when user declines mosh-server installation — fall back to SSH
    func declineMoshInstall() async {
        showMoshInstallOffer = false

        guard let coordinator, let server = pendingServer else { return }
        isConnecting = true
        connectionPhase = "Falling back to SSH..."
        do {
            let outcome = try await coordinator.fallBackToSSH()
            adoptCoordinatorSessions(coordinator)
            applyCoordinatorOutcome(outcome)
        } catch {
            presentConnectionError(error)
        }
        isConnecting = false

        if connectionState == .connected {
            server.lastConnected = Date()
        }
    }

    // Quick-launch: retrieve stored credentials and connect immediately
    func quickLaunch(server: Server) async {
        do {
            switch server.authMethod {
            case .password:
                guard let password = try KeychainService.shared.retrievePassword(forServer: server.id) else {
                    throw SSHConnectionError.authenticationFailed(method: "password")
                }
                await connect(server: server, password: password, keyTag: nil)
            case .key:
                guard let keyID = server.keyID,
                      try KeychainService.shared.retrievePrivateKey(withTag: keyID) != nil else {
                    throw SSHConnectionError.keyNotFound
                }
                await connect(server: server, password: nil, keyTag: keyID)
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// Check if a server has stored credentials available for quick-launch
    static func hasStoredCredentials(for server: Server) -> Bool {
        switch server.authMethod {
        case .password:
            do {
                return try KeychainService.shared.retrievePassword(forServer: server.id) != nil
            } catch {
                return false
            }
        case .key:
            guard let keyID = server.keyID else { return false }
            do {
                return try KeychainService.shared.retrievePrivateKey(withTag: keyID) != nil
            } catch {
                return false
            }
        }
    }

    // MARK: - Private

    private func performConnection(
        server: Server,
        password: String?,
        keyTag: String?,
        generation: UUID
    ) async {
        defer {
            if connectionGeneration == generation {
                isConnecting = false
            }
        }

        while !Task.isCancelled, connectionGeneration == generation {
            let coordinator = ConnectionCoordinator()
            self.coordinator = coordinator
            coordinator.onPhaseChanged = { [weak self] phase in
                self?.connectionPhase = phase.statusText
            }

            do {
                let outcome = try await coordinator.prepare(
                    server: server,
                    password: password,
                    keyTag: keyTag
                )
                guard !Task.isCancelled, connectionGeneration == generation else {
                    await coordinator.cancel()
                    return
                }

                adoptCoordinatorSessions(coordinator)
                applyCoordinatorOutcome(outcome)
                if connectionState == .connected {
                    server.lastConnected = Date()
                }
                return
            } catch is CancellationError {
                await coordinator.cancel()
                return
            } catch let error as SSHHostKeyTrustError {
                guard case .untrusted(let identity) = error else {
                    presentConnectionError(error)
                    return
                }

                pendingHostKeyIdentity = identity
                connectionPhase = "Verify the SSH host-key fingerprint..."
                let trusted = await HostKeyTrustCoordinator.shared.requestTrust(for: identity)
                guard !Task.isCancelled, connectionGeneration == generation else {
                    await coordinator.cancel()
                    return
                }
                guard trusted else {
                    presentConnectionError(SSHHostKeyTrustError.declined(
                        hostname: identity.hostname,
                        port: identity.port
                    ))
                    return
                }

                do {
                    try KnownHostsService.shared.trust(identity)
                } catch {
                    presentConnectionError(error)
                    return
                }

                await coordinator.cancel()
                errorMessage = nil
                showError = false
                pendingHostKeyIdentity = nil
            } catch {
                presentConnectionError(error)
                await coordinator.cancel()
                self.coordinator = nil
                return
            }
        }
    }

    private func adoptCoordinatorSessions(_ coordinator: ConnectionCoordinator) {
        sshSession = coordinator.sshSession
        moshSession = coordinator.moshSession
    }

    private func applyCoordinatorOutcome(_ outcome: ConnectionCoordinatorOutcome) {
        switch outcome {
        case .connected:
            showTmuxPicker = false
        case .awaitingTmuxChoice(let sessions):
            detectedTmuxSessions = sessions
            showTmuxPicker = true
        case .moshInstallationRequired(let packageManager):
            detectedPackageManager = packageManager
            if packageManager == nil {
                presentConnectionError(ConnectionCoordinatorError.moshUnavailable)
            } else {
                showMoshInstallOffer = true
            }
        case .cancelled:
            showTmuxPicker = false
        }
    }

    private func presentConnectionError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
