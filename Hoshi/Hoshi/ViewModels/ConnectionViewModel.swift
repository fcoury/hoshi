import Foundation
import SwiftUI
import SwiftData

@MainActor
@Observable
final class ConnectionViewModel {
    // Active session — either SSH or Mosh
    var sshSession: SSHSession?
    var moshSession: MoshSession?
    var isConnecting = false
    var errorMessage: String?
    var showError = false

    // Mosh-specific UI state
    var connectionPhase: String = ""
    var showMoshInstallOffer = false
    var detectedPackageManager: RemotePackageManager?

    // tmux session picker state
    var showTmuxPicker = false
    var detectedTmuxSessions: [TmuxSessionInfo] = []

    // Stashed credentials for fallback/install retry
    private var pendingServer: Server?
    private var pendingPassword: String?
    private var pendingKeyTag: String?

    // The active session's connection state — suppress .connected until terminal is open
    var connectionState: ConnectionState {
        if showTmuxPicker { return .connecting }
        if let moshSession { return moshSession.connectionState }
        if let sshSession { return sshSession.connectionState }
        return .disconnected
    }

    // Whether a session object exists (even if currently disconnected/reconnecting)
    var hasActiveSession: Bool {
        sshSession != nil || moshSession != nil
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
    }

    // Send raw keystroke bytes to the active session
    func sendBytes(_ bytes: ArraySlice<UInt8>) async {
        let data = Data(bytes)
        if let moshSession { await moshSession.send(data) }
        else if let sshSession { await sshSession.send(data) }
    }

    // Connect to a server, routing to SSH or Mosh based on toggle
    func connect(server: Server, password: String?, keyTag: String?) async {
        isConnecting = true
        errorMessage = nil
        connectionPhase = ""

        // Stash credentials for potential fallback
        pendingServer = server
        pendingPassword = password
        pendingKeyTag = keyTag

        if server.useMosh {
            await connectMosh(server: server, password: password, keyTag: keyTag)
        } else {
            await connectSSH(server: server, password: password, keyTag: keyTag)
        }

        isConnecting = false

        // Update lastConnected on success (unless waiting for tmux picker)
        if connectionState == .connected {
            server.lastConnected = Date()
        }
    }

    // Handle the user's tmux session choice, creating a distinct saved entry if needed
    func completeTmuxChoice(_ choice: TmuxChoice, modelContext: ModelContext? = nil) async {
        showTmuxPicker = false
        guard let sshSession else { return }

        // Set the initial command based on user choice
        switch choice {
        case .attach(let session):
            sshSession.initialCommand = TmuxDetectionService.attachCommand(sessionName: session.name)
            // Create or find a distinct entry for this server+tmux combo
            ensureTmuxEntry(sessionName: session.name, modelContext: modelContext)
        case .newSession:
            sshSession.initialCommand = TmuxDetectionService.newSessionCommand()
        case .skip:
            break
        }

        // Open the PTY (sends initial command if set)
        await sshSession.openTerminal()

        if connectionState == .connected {
            pendingServer?.lastConnected = Date()
        }
    }

    // Create a saved connection entry for a server+tmux combo if one doesn't already exist
    private func ensureTmuxEntry(sessionName: String, modelContext: ModelContext?) {
        guard let server = pendingServer, let modelContext else { return }

        // If this server entry already targets this tmux session, just update it
        if server.tmuxSession == sessionName {
            return
        }

        // Check if a matching entry already exists
        let hostname = server.hostname
        let port = server.port
        let username = server.username
        let predicate = #Predicate<Server> {
            $0.hostname == hostname &&
            $0.port == port &&
            $0.username == username &&
            $0.tmuxSession == sessionName
        }
        let descriptor = FetchDescriptor<Server>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            // Entry already exists — switch to it for lastConnected tracking
            pendingServer = existing
            return
        }

        // Create a new entry for this server+tmux session combo
        let newEntry = Server(
            name: "\(server.name) (\(sessionName))",
            hostname: server.hostname,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            useMosh: server.useMosh,
            tmuxSession: sessionName
        )
        modelContext.insert(newEntry)

        // Copy stored password to the new entry's Keychain slot
        if server.authMethod == .password,
           let password = try? KeychainService.shared.retrievePassword(forServer: server.id) {
            try? KeychainService.shared.storePassword(password, forServer: newEntry.id)
        }

        pendingServer = newEntry
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
            // If the SSH session silently died while backgrounded, trigger reconnect
            if sshSession.connectionState == .disconnected {
                Task {
                    await sshSession.reconnect()
                }
            }
        }
    }

    // Disconnect the current session (user-initiated)
    func disconnect() async {
        if let moshSession {
            await moshSession.disconnect()
            self.moshSession = nil
        }
        if let sshSession {
            await sshSession.disconnect()
            self.sshSession = nil
        }
        showTmuxPicker = false
        detectedTmuxSessions = []
        pendingServer = nil
        pendingPassword = nil
        pendingKeyTag = nil
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
        guard let moshSession, let pm = detectedPackageManager else { return }
        showMoshInstallOffer = false
        isConnecting = true
        connectionPhase = "Installing mosh-server..."

        await moshSession.installAndConnect(
            using: pm,
            password: pendingPassword,
            privateKeyTag: pendingKeyTag
        )

        if case .error(let msg) = moshSession.connectionState {
            errorMessage = msg
            showError = true
        }

        isConnecting = false

        if moshSession.connectionState == .connected {
            pendingServer?.lastConnected = Date()
        }
    }

    // Called when user declines mosh-server installation — fall back to SSH
    func declineMoshInstall() async {
        showMoshInstallOffer = false

        // Clean up mosh session
        await moshSession?.disconnect()
        moshSession = nil

        // Fall back to plain SSH
        guard let server = pendingServer else { return }
        isConnecting = true
        connectionPhase = "Falling back to SSH..."
        await connectSSH(server: server, password: pendingPassword, keyTag: pendingKeyTag)
        isConnecting = false

        if connectionState == .connected {
            server.lastConnected = Date()
        }
    }

    // Quick-launch: retrieve stored credentials and connect immediately
    func quickLaunch(server: Server) async {
        // Resolve credentials from Keychain
        let password: String? = server.authMethod == .password
            ? (try? KeychainService.shared.retrievePassword(forServer: server.id))
            : nil
        let keyTag: String? = server.authMethod == .key
            ? SSHKeyService.shared.listKeys().first
            : nil

        await connect(server: server, password: password, keyTag: keyTag)
    }

    /// Check if a server has stored credentials available for quick-launch
    static func hasStoredCredentials(for server: Server) -> Bool {
        switch server.authMethod {
        case .password:
            return (try? KeychainService.shared.retrievePassword(forServer: server.id)) != nil
        case .key:
            return !SSHKeyService.shared.listKeys().isEmpty
        }
    }

    // MARK: - Private

    private func connectSSH(server: Server, password: String?, keyTag: String?) async {
        connectionPhase = "Connecting via SSH..."
        let session = SSHSession(server: server)
        self.sshSession = session

        // Establish SSH connection without opening PTY yet
        await session.connectOnly(password: password, privateKeyTag: keyTag)

        if case .error(let message) = session.connectionState {
            errorMessage = message
            showError = true
            self.sshSession = nil
            return
        }

        // If this server has a saved tmux session, validate it still exists before auto-attaching
        if let tmux = server.tmuxSession {
            connectionPhase = "Checking tmux session: \(tmux)..."
            if let client = session.client {
                let tmuxService = TmuxDetectionService(client: client)
                let sessionExists = await validateTmuxSession(tmux, using: tmuxService)

                if sessionExists {
                    // Session still exists — auto-attach
                    connectionPhase = "Attaching to tmux: \(tmux)..."
                    session.initialCommand = TmuxDetectionService.attachCommand(sessionName: tmux)
                    await session.openTerminal()
                    return
                } else {
                    // Session no longer exists — fall back to tmux picker
                    connectionPhase = "Session '\(tmux)' not found, loading sessions..."
                    do {
                        let sessions = try await tmuxService.listSessions()
                        detectedTmuxSessions = sessions
                        showTmuxPicker = true
                        return
                    } catch {
                        // tmux detection failed — open terminal without tmux
                        await session.openTerminal()
                        return
                    }
                }
            } else {
                // No client available — fall back to direct attach (best effort)
                connectionPhase = "Attaching to tmux: \(tmux)..."
                session.initialCommand = TmuxDetectionService.attachCommand(sessionName: tmux)
                await session.openTerminal()
                return
            }
        }

        // Detect tmux sessions on the remote host
        guard let client = session.client else {
            // Fallback: open terminal without tmux
            await session.openTerminal()
            return
        }

        connectionPhase = "Checking for tmux sessions..."
        let tmuxService = TmuxDetectionService(client: client)

        do {
            let tmuxAvailable = try await tmuxService.isTmuxAvailable()
            guard tmuxAvailable else {
                // tmux not installed — go straight to shell
                await session.openTerminal()
                return
            }

            let sessions = try await tmuxService.listSessions()
            // Show the picker — user can attach, create new, or skip
            detectedTmuxSessions = sessions
            showTmuxPicker = true

        } catch {
            // tmux detection failed — proceed without it
            await session.openTerminal()
        }
    }

    // Check if a specific tmux session still exists on the remote host
    private func validateTmuxSession(_ sessionName: String, using service: TmuxDetectionService) async -> Bool {
        do {
            let sessions = try await service.listSessions()
            return sessions.contains { $0.name == sessionName }
        } catch {
            return false
        }
    }

    private func connectMosh(server: Server, password: String?, keyTag: String?) async {
        connectionPhase = "Connecting via SSH..."
        let session = MoshSession(server: server)
        self.moshSession = session

        await session.connect(password: password, privateKeyTag: keyTag)

        // Check if mosh-server was not found — offer installation
        if let status = session.moshServerStatus {
            switch status {
            case .notFound(let pm):
                detectedPackageManager = pm
                showMoshInstallOffer = true
                return
            case .notFoundNoPackageManager:
                errorMessage = "mosh-server not found and no package manager detected on the remote host."
                showError = true
                return
            case .available:
                break
            }
        }

        if case .error(let message) = session.connectionState {
            errorMessage = message
            showError = true
            self.moshSession = nil
        }
    }
}
