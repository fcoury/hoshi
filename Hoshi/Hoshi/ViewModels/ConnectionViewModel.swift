import Foundation
import SwiftUI
import Combine
import Citadel

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
    var presentedError: ErrorPresentation?
    var transportFallbackNotice: ErrorPresentation?
    var showError = false
    var onAgentEvent: (@MainActor (AgentEventEnvelope) -> Void)? {
        didSet { bindAgentEvents() }
    }
    var onTerminalNotification: (@MainActor (TerminalDesktopNotification) -> Void)?
    /// Called when Herdr agent states change, for example to refresh Live Activities.
    var onHerdrInventoryChange: (@MainActor () -> Void)?

    // Mosh-specific UI state
    var connectionPhase: String = ""
    var showMoshInstallOffer = false
    var detectedPackageManager: RemotePackageManager?

    // tmux session picker state
    var showTmuxPicker = false {
        didSet { bindSessionState() }
    }
    var detectedTmuxSessions: [TmuxSessionInfo] = []
    var tmuxAvailable = false

    // Herdr state. Discovered while connecting and kept current by the monitor.
    var detectedHerdr: HerdrInventory?
    /// What this terminal shows from Herdr, if anything.
    private(set) var herdrAttachment: HerdrAttachment?
    /// Set before connecting to open a Herdr target directly.
    @ObservationIgnored
    var preferredHerdrAttachment: HerdrAttachment?
    /// A mosh-server an earlier connection of this session left running (the app was
    /// killed, or it never acknowledged our shutdown); the next Mosh launch stops it.
    var moshServerPIDToReplace: Int32?
    /// Called once a connection is established, so the session's saved state can follow.
    var onConnectionEstablished: (() -> Void)?

    /// The mosh-server to stop if this session is restored after the app was killed.
    var runningMoshServerPID: Int32? {
        moshSession?.runningServerPID ?? moshServerPIDToReplace
    }

    var herdrAttentionCount: Int { detectedHerdr?.attentionCount ?? 0 }
    /// An agent whose reply card should open over this terminal.
    var pendingHerdrReply: HerdrAgentTarget?
    /// Agents waiting on an approval or question prompt.
    var herdrBlockedCount: Int {
        detectedHerdr?.runningSessions.reduce(0) { total, session in
            total + session.agents.filter { $0.status == .blocked }.count
        } ?? 0
    }

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
    private(set) var currentRecoveryStatus: ConnectionRecoveryStatus = .idle
    /// Smoothed transport round-trip time (Mosh only; SSH has no cheap probe).
    private(set) var roundTripTime: TimeInterval?

    // Combine subscription that forwards session state changes
    @ObservationIgnored
    private var sessionStateCancellable: AnyCancellable?
    @ObservationIgnored
    private var recoveryStatusCancellable: AnyCancellable?
    @ObservationIgnored
    private var roundTripCancellable: AnyCancellable?
    @ObservationIgnored
    private var coordinator: ConnectionCoordinator?
    @ObservationIgnored
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration: UUID?
    @ObservationIgnored
    private var herdrMonitor: HerdrAgentMonitor?
    /// A verified SSH client for Herdr polling once Mosh has closed its bootstrap.
    @ObservationIgnored
    private var auxiliaryClient: SSHClient?

    // The active session's connection state — suppress .connected until terminal is open
    var connectionState: ConnectionState {
        if showTmuxPicker { return .connecting }
        return currentSessionState
    }

    var recoveryStatus: ConnectionRecoveryStatus {
        currentRecoveryStatus
    }

    var canAcceptTerminalInput: Bool {
        connectionState == .connected && recoveryStatus == .idle
    }

    // Subscribe to the active session's @Published connectionState and
    // mirror it into currentSessionState so @Observable can track it.
    private func bindSessionState() {
        sessionStateCancellable?.cancel()
        sessionStateCancellable = nil
        recoveryStatusCancellable?.cancel()
        recoveryStatusCancellable = nil
        roundTripCancellable?.cancel()
        roundTripCancellable = nil
        roundTripTime = nil

        if showTmuxPicker {
            currentSessionState = .connecting
            currentRecoveryStatus = .idle
        } else if let moshSession {
            currentSessionState = moshSession.connectionState
            currentRecoveryStatus = moshSession.recoveryStatus
            sessionStateCancellable = moshSession.$connectionState
                .sink { [weak self] state in
                    self?.currentSessionState = state
                }
            recoveryStatusCancellable = moshSession.$recoveryStatus
                .sink { [weak self] status in
                    self?.currentRecoveryStatus = status
                }
            roundTripCancellable = moshSession.$roundTripTime
                .sink { [weak self] roundTripTime in
                    self?.roundTripTime = roundTripTime
                }
        } else if let sshSession {
            currentSessionState = sshSession.connectionState
            currentRecoveryStatus = sshSession.recoveryStatus
            sessionStateCancellable = sshSession.$connectionState
                .sink { [weak self] state in
                    self?.currentSessionState = state
                }
            recoveryStatusCancellable = sshSession.$recoveryStatus
                .sink { [weak self] status in
                    self?.currentRecoveryStatus = status
                }
        } else {
            currentSessionState = .disconnected
            currentRecoveryStatus = .idle
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

    var canRememberSSHFallback: Bool {
        connectionState == .connected
            && sshSession != nil
            && transportFallbackNotice?.context.transport == ConnectionTransportPolicy.auto.rawValue
    }

    var selectedSSHKeyID: String? {
        pendingKeyTag
    }

    enum FileTransferConnectionSource: Equatable {
        case activeSSH
        case retainedMoshBootstrap
        case verifiedMoshReconnect
    }

    var fileTransferConnectionSource: FileTransferConnectionSource? {
        guard connectionState == .connected else { return nil }
        if sshSession?.client != nil { return .activeSSH }
        if moshSession?.bootstrapClient != nil { return .retainedMoshBootstrap }
        if moshSession != nil { return .verifiedMoshReconnect }
        return nil
    }

    /// Mosh closes its bootstrap after UDP starts, so file transfer reconnects through pinned-host SSH.
    func withVerifiedFileTransferClient<Result: Sendable>(
        _ operation: @escaping @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        guard canAcceptTerminalInput else { throw FileUploadError.disconnected }

        if let client = sshSession?.client {
            return try await operation(client)
        }
        if let client = moshSession?.bootstrapClient {
            return try await operation(client)
        }

        let client = try await makeVerifiedClient()
        do {
            let result = try await operation(client)
            try? await client.close()
            return result
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Opens a fresh SSH connection with the session's verified host key and
    /// stored credentials.
    private func makeVerifiedClient() async throws -> SSHClient {
        guard let server = pendingServer ?? moshSession?.server ?? sshSession?.server else {
            throw FileUploadError.disconnected
        }

        let password: String?
        switch server.authMethod {
        case .password:
            if let pendingPassword {
                password = pendingPassword
            } else {
                password = try KeychainService.shared.retrievePassword(forServer: server.id)
            }
            guard password != nil else { throw FileUploadError.missingCredentials }
        case .key:
            password = nil
        }

        let keyTag = pendingKeyTag ?? server.keyID
        if server.authMethod == .key, keyTag == nil {
            throw FileUploadError.missingCredentials
        }

        return try await SSHConnectionService.connect(
            server: server,
            password: password,
            privateKeyTag: keyTag
        )
    }

    // MARK: - Herdr

    /// Runs a non-interactive command on the host: over the SSH session, the
    /// Mosh bootstrap, or a retained verified client once that has closed.
    func runRemoteCommand(_ command: String) async throws -> String {
        let client: SSHClient
        if let sshClient = sshSession?.client {
            client = sshClient
        } else if let bootstrap = moshSession?.bootstrapClient {
            client = bootstrap
        } else if let auxiliaryClient {
            client = auxiliaryClient
        } else {
            let created = try await makeVerifiedClient()
            auxiliaryClient = created
            client = created
        }

        do {
            let buffer = try await client.executeCommand(command)
            return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        } catch {
            if client === auxiliaryClient {
                // Reconnect on the next call instead of reusing a dead channel.
                auxiliaryClient = nil
                try? await client.close()
            }
            throw error
        }
    }

    func refreshHerdr() async {
        if let herdrMonitor {
            await herdrMonitor.pollNow()
            return
        }
        // Herdr was not found while connecting; look again in case it was
        // installed or started since. Failures leave the terminal untouched.
        guard let output = try? await runRemoteCommand(HerdrDiscovery.remoteCommand) else { return }
        detectedHerdr = HerdrDiscovery.parse(output)
        if canAcceptTerminalInput {
            startHerdrMonitorIfNeeded()
        }
    }

    func herdrAgent(for target: HerdrAgentTarget) -> HerdrAgent? {
        detectedHerdr?.session(for: target)?.agent(paneID: target.paneID)
    }

    /// Whether focusing `target` switches what this terminal shows.
    func canFocusHerdrInPlace(_ target: HerdrAgentTarget) -> Bool {
        guard let herdrAttachment, let session = detectedHerdr?.session(for: target) else { return false }
        return herdrAttachment.shows(session)
    }

    /// The agent's recent output, without styling.
    func readHerdrAgent(_ target: HerdrAgentTarget, lines: Int = 60) async throws -> String {
        let executable = try herdrExecutable()
        guard let command = HerdrCommand.readAgent(
            paneID: target.paneID,
            session: target.session,
            machineID: target.machineID,
            executable: executable,
            lines: lines
        ) else { throw HerdrActionError.invalidTarget }
        return try await runHerdrAction(command).output
    }

    func sendHerdrKeys(_ keys: [HerdrKey], to target: HerdrAgentTarget) async throws {
        let executable = try herdrExecutable()
        guard let command = HerdrCommand.sendKeys(
            keys,
            paneID: target.paneID,
            session: target.session,
            machineID: target.machineID,
            executable: executable
        ) else { throw HerdrActionError.invalidTarget }
        _ = try await runHerdrAction(command)
        await herdrMonitor?.pollNow()
    }

    func submitHerdrText(_ text: String, to target: HerdrAgentTarget) async throws {
        let executable = try herdrExecutable()
        let isBlocked = herdrAgent(for: target)?.status == .blocked
        guard let command = HerdrCommand.submitText(
            text,
            toBlockedAgent: isBlocked,
            paneID: target.paneID,
            session: target.session,
            machineID: target.machineID,
            executable: executable
        ) else { throw HerdrActionError.invalidText }
        _ = try await runHerdrAction(command)
        await herdrMonitor?.pollNow()
    }

    private func herdrExecutable() throws -> String {
        guard let executable = detectedHerdr?.executable else { throw HerdrActionError.unavailable }
        return executable
    }

    private func runHerdrAction(_ command: String) async throws -> HerdrCommand.Result {
        let result = HerdrCommand.parseResult(try await runRemoteCommand(HerdrCommand.captured(command)))
        guard result.succeeded else {
            throw HerdrActionError.failed(result.errorMessage)
        }
        return result
    }

    /// Switches the Herdr UI shown in this terminal to `agent`. Herdr focus is
    /// shared, so other clients attached to the same session follow along.
    func focusHerdrAgent(_ target: HerdrAgentTarget) async throws {
        guard let herdr = detectedHerdr,
              let command = HerdrCommand.focusAgent(
                paneID: target.paneID,
                session: target.session,
                machineID: target.machineID,
                executable: herdr.executable
              ) else {
            throw HerdrActionError.invalidTarget
        }
        _ = try await runHerdrAction(command)
        await herdrMonitor?.pollNow()
    }

    private func startHerdrMonitorIfNeeded() {
        guard herdrMonitor == nil, let detectedHerdr else { return }
        let server = pendingServer ?? sshSession?.server ?? moshSession?.server
        let monitor = HerdrAgentMonitor(
            hostname: server?.hostname,
            hostKey: server.map { "\($0.username)@\($0.hostname):\($0.port)" },
            runner: { [weak self] command in
                guard let self else { throw CancellationError() }
                return try await self.runRemoteCommand(command)
            },
            attachment: { [weak self] in self?.herdrAttachment },
            onEvent: { [weak self] event in
                self?.onAgentEvent?(event)
            },
            onInventory: { [weak self] inventory in
                guard let self else { return }
                let changed = self.detectedHerdr != inventory
                self.detectedHerdr = inventory
                if changed { self.onHerdrInventoryChange?() }
            }
        )
        herdrMonitor = monitor
        monitor.start(baseline: detectedHerdr)
    }

    private func stopHerdrMonitor() async {
        herdrMonitor?.stop()
        herdrMonitor = nil
        if let auxiliaryClient {
            self.auxiliaryClient = nil
            try? await auxiliaryClient.close()
        }
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
        guard canAcceptTerminalInput else { return }
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
        presentedError = nil
        transportFallbackNotice = nil
        showError = false
        connectionPhase = ""
        showMoshInstallOffer = false
        detectedTmuxSessions = []

        if server.authMethod == .key {
            guard let keyTag else {
                presentConnectionError(SSHConnectionError.keyNotFound, server: server)
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
            herdrAttachment = HerdrAttachment(choice: choice)
            startHerdrMonitorIfNeeded()

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
            if coordinator.tmuxAvailable {
                detectedTmuxSessions = try await coordinator.refreshTmuxSessions()
            }
            if coordinator.detectedHerdr != nil {
                detectedHerdr = try await coordinator.refreshHerdr()
            }
        } catch {
            presentConnectionError(error, operation: .tmux)
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
            await self?.stopHerdrMonitor()
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
            if (sshSession.connectionState == .disconnected || sshSession.connectionState == .reconnecting)
                && !sshSession.sessionEndedNormally {
                Task {
                    await sshSession.reconnect()
                }
            }
        }
    }

    func handleSceneBackground() {
        moshSession?.handleAppBackground()
        sshSession?.handleAppBackground()
    }

    func retryConnection() async {
        if let moshSession {
            await moshSession.retryRecovery()
        } else if let sshSession {
            await sshSession.retryRecovery()
        }
    }

    func restartConnection() async {
        guard let server = pendingServer ?? moshSession?.server ?? sshSession?.server else { return }
        let password = pendingPassword
        let keyTag = pendingKeyTag ?? server.keyID

        connectionGeneration = nil
        connectionTask?.cancel()
        connectionTask = nil
        await stopHerdrMonitor()
        let previousMosh = moshSession
        await coordinator?.cancel()
        coordinator = nil
        await moshSession?.disconnect()
        await sshSession?.disconnect()
        // Still set if the old server never acknowledged the shutdown (it was unreachable).
        if let leftover = previousMosh?.runningServerPID {
            moshServerPIDToReplace = leftover
        }
        moshSession = nil
        sshSession = nil

        await connect(server: server, password: password, keyTag: keyTag)
    }

    func presentRecoveryDetails() {
        if let error = moshSession?.connectionError ?? sshSession?.connectionError {
            presentConnectionError(error)
        } else if case .unavailable(let message) = recoveryStatus {
            presentConnectionError(ErrorMessageFailure(message: message))
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
        await stopHerdrMonitor()
        moshSession = nil
        sshSession = nil
        showTmuxPicker = false
        detectedTmuxSessions = []
        tmuxAvailable = false
        detectedHerdr = nil
        herdrAttachment = nil
        pendingServer = nil
        pendingPassword = nil
        pendingKeyTag = nil
        pendingHostKeyIdentity = nil
    }

    // Send data to the active session
    func send(_ data: Data) async {
        guard canAcceptTerminalInput else { return }
        if let moshSession { await moshSession.send(data) }
        else if let sshSession { await sshSession.send(data) }
    }

    // Send a string to the active session
    func sendString(_ string: String) async {
        guard canAcceptTerminalInput else { return }
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
                    throw SSHConnectionError.passwordNotFound
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
            presentConnectionError(error, server: server)
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
            coordinator.preferredHerdrAttachment = preferredHerdrAttachment
            coordinator.replacingMoshServerPID = moshServerPIDToReplace
            self.coordinator = coordinator
            coordinator.onPhaseChanged = { [weak self] phase in
                self?.connectionPhase = phase.statusText
            }
            coordinator.onTransportFallback = { [weak self] error in
                self?.presentTransportFallback(error, server: server)
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
                    moshServerPIDToReplace = nil
                    onConnectionEstablished?()
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
                presentedError = nil
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

    private func syncMultiplexerState() {
        tmuxAvailable = coordinator?.tmuxAvailable ?? false
        detectedHerdr = coordinator?.detectedHerdr
        herdrAttachment = coordinator?.herdrAttachment
    }

    private func adoptCoordinatorSessions(_ coordinator: ConnectionCoordinator) {
        sshSession = coordinator.sshSession
        moshSession = coordinator.moshSession
    }

    private func applyCoordinatorOutcome(_ outcome: ConnectionCoordinatorOutcome) {
        switch outcome {
        case .connected:
            showTmuxPicker = false
            syncMultiplexerState()
            startHerdrMonitorIfNeeded()
        case .awaitingTmuxChoice(let sessions):
            detectedTmuxSessions = sessions
            syncMultiplexerState()
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

    func presentTransportFallback(_ error: any Error, server: Server) {
        guard ErrorPresentation.shouldPresent(error) else { return }
        transportFallbackNotice = ErrorPresentation.classify(
            error,
            context: .connection(server: server, phase: ConnectionPhase.sshFallback.statusText)
        )
    }

    func dismissTransportFallbackNotice() {
        transportFallbackNotice = nil
    }

    func presentConnectionError(
        _ error: any Error,
        server: Server? = nil,
        operation: ErrorOperation = .connection
    ) {
        guard ErrorPresentation.shouldPresent(error) else {
            presentedError = nil
            errorMessage = nil
            showError = false
            return
        }
        let server = server ?? pendingServer ?? sshSession?.server ?? moshSession?.server
        let context = server.map {
            ErrorContext.connection(server: $0, phase: connectionPhase, operation: operation)
        } ?? ErrorContext(operation: operation, phase: connectionPhase)
        let presentation = ErrorPresentation.classify(error, context: context)
        presentedError = presentation
        errorMessage = presentation.explanation
        showError = true
    }
}

enum HerdrActionError: LocalizedError, Equatable {
    case unavailable
    case invalidTarget
    case invalidText
    case failed(String?)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Herdr is not available on this server."
        case .invalidTarget: "That Herdr agent can no longer be reached."
        case .invalidText: "Enter a reply of up to 8 KB."
        case .failed(let message): message.map { "Herdr: \($0)" } ?? "Herdr did not accept the request."
        }
    }
}
