import SwiftUI
import SwiftData

/// Root view: server list with active session carousel.
///
/// Uses a custom `ScrollView` + `LazyVStack` instead of `List` so that backgrounds,
/// separators, and section headers can be fully themed from `TerminalTheme`.
/// The trade-off is that built-in swipe actions are unavailable; delete is
/// accessible only via context menu.
///
/// Session lifecycle flows through three sheets presented in sequence:
/// 1. `ConnectView` — credential entry (or skipped via quick-launch)
/// 2. `TmuxSessionPickerView` — tmux session selection (if server has tmux)
/// 3. `TerminalView` — full-screen terminal (via `.fullScreenCover`)
struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Server.lastConnected, order: .reverse) private var servers: [Server]

    @State private var showAddServer = false
    @State private var selectedServer: Server?
    @State private var editingServer: Server?
    @State private var showSettings = false

    // Multi-session state
    @State private var sessionManager = SessionManager()
    @State private var quickLaunching = false
    @State private var connectingSession: ManagedSession?
    @State private var quickLaunchErrorMessage: String?
    @State private var showMaxSessionsAlert = false

    private let appearance = AppearanceSettings.shared
    private var theme: TerminalTheme { appearance.currentTheme }

    var body: some View {
        NavigationStack {
            Group {
                if servers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("Hoshi")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $editingServer) { server in
                AddServerView(existingServer: server)
            }
            // ConnectView — credentials entry for the session being connected
            .sheet(item: $selectedServer, onDismiss: {
                guard let session = connectingSession else { return }
                if session.connectionVM.showTmuxPicker {
                    // Hand off to tmux picker sheet
                    session.connectionVM.showTmuxPicker = false
                    sessionManager.tmuxPickerSession = session
                    connectingSession = nil
                } else if session.connectionVM.connectionState == .connected {
                    // PTY is open — safe to show terminal
                    sessionManager.switchTo(sessionID: session.id)
                    connectingSession = nil
                } else {
                    // Connection cancelled or failed — clean up
                    Task { await sessionManager.closeSession(id: session.id) }
                    connectingSession = nil
                }
            }) { server in
                if let session = connectingSession {
                    ConnectView(server: server, connectionVM: session.connectionVM)
                }
            }
            // Tmux session picker — shown per-session after SSH connects
            .sheet(item: $sessionManager.tmuxPickerSession) { session in
                TmuxSessionPickerView(
                    sessions: session.connectionVM.detectedTmuxSessions
                ) { choice in
                    Task {
                        let tmuxName = await session.connectionVM.completeTmuxChoice(choice)
                        session.tmuxSession = tmuxName
                        sessionManager.tmuxPickerSession = nil
                        // Open the session full-screen after tmux attach
                        sessionManager.switchTo(sessionID: session.id)
                    }
                }
            }
            // Full-screen terminal — shown when a session is active
            .fullScreenCover(item: Binding<ManagedSession?>(
                get: { sessionManager.activeSession },
                set: { if $0 == nil { sessionManager.returnToServerList() } }
            )) { session in
                TerminalView(
                    connectionVM: session.connectionVM,
                    managedSession: session,
                    canSwapSession: sessionManager.sessions.count >= 2,
                    onSwapSession: {
                        sessionManager.switchToPrevious()
                    },
                    onDismiss: {
                        sessionManager.returnToServerList()
                    }
                )
            }
        }
        // Max sessions alert
        .alert("Session Limit Reached", isPresented: $showMaxSessionsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can have up to \(SessionManager.maxSessions) active sessions. Close an existing session to open a new one.")
        }
        // Quick-launch error alert
        .alert("Connection Failed", isPresented: Binding(
            get: { quickLaunchErrorMessage != nil },
            set: { if !$0 { quickLaunchErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = quickLaunchErrorMessage {
                Text(error)
            }
        }
        // Quick-launch connecting overlay
        .overlay {
            if quickLaunching, let session = connectingSession {
                ZStack {
                    SwiftUI.Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(session.connectionVM.connectionPhase.isEmpty
                             ? "Connecting..."
                             : session.connectionVM.connectionPhase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .preferredColorScheme(.dark)
        .toolbarBackground(SwiftUI.Color(theme.chromeSurface), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                sessionManager.handleSceneActive()
            case .background:
                sessionManager.handleSceneBackground()
            default:
                break
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("$ add a server to get started")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
        } actions: {
            Button("Add Server") {
                showAddServer = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Terminal-style section header: monospace caps with a subtle trailing line
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SwiftUI.Color(theme.secondaryForeground))

            Rectangle()
                .fill(SwiftUI.Color(theme.separator))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Active sessions carousel
                if sessionManager.hasActiveSessions {
                    SessionCarouselView(
                        sessions: sessionManager.sessions,
                        onTap: { sessionID in
                            sessionManager.switchTo(sessionID: sessionID)
                        },
                        onDuplicate: { sessionID in
                            duplicateSession(id: sessionID)
                        },
                        onClose: { sessionID in
                            Task {
                                await sessionManager.closeSession(id: sessionID)
                            }
                        }
                    )
                }

                // Server list section
                sectionHeader("SERVERS")

                ForEach(servers) { server in
                    ServerRow(server: server, theme: theme)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            connectToServer(server)
                        }
                        .contextMenu {
                            Button {
                                editingServer = server
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Button {
                                duplicateServer(server)
                            } label: {
                                Label("Duplicate Server", systemImage: "doc.on.doc")
                            }

                            Button(role: .destructive) {
                                deleteServer(server)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }

                    // Subtle separator between rows
                    if server.id != servers.last?.id {
                        Rectangle()
                            .fill(SwiftUI.Color(theme.separator))
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .background(SwiftUI.Color(theme.chromeBackground))
    }

    // Create a session and connect — sequential flow avoids race conditions
    private func connectToServer(_ server: Server) {
        HapticService.lightTap()
        launchSession(for: server)
    }

    private func duplicateSession(id: UUID) {
        HapticService.lightTap()

        guard let sourceSession = sessionManager.sessions.first(where: { $0.id == id }) else { return }
        guard let sourceServer = servers.first(where: { $0.id == sourceSession.serverID }) else {
            quickLaunchErrorMessage = "Unable to duplicate \(sourceSession.serverName) because its server profile no longer exists."
            return
        }

        launchSession(for: sourceServer, tmuxOverride: sourceSession.tmuxSession)
    }

    private func launchSession(for server: Server, tmuxOverride: String? = nil) {
        quickLaunchErrorMessage = nil
        let connectionServer = connectionServer(from: server, tmuxOverride: tmuxOverride)

        guard let session = sessionManager.createSession(for: connectionServer) else {
            selectedServer = nil
            showMaxSessionsAlert = true
            return
        }

        session.tmuxSession = connectionServer.tmuxSession
        connectingSession = session

        if ConnectionViewModel.hasStoredCredentials(for: connectionServer) {
            // Quick-launch: await full connection, then transition
            quickLaunching = true
            Task {
                await session.connectionVM.quickLaunch(server: connectionServer)
                quickLaunching = false

                if session.connectionVM.showTmuxPicker {
                    // Hand off to tmux picker sheet
                    session.connectionVM.showTmuxPicker = false
                    sessionManager.tmuxPickerSession = session
                    connectingSession = nil
                } else if session.connectionVM.connectionState == .connected {
                    // PTY is open — safe to show terminal
                    sessionManager.switchTo(sessionID: session.id)
                    connectingSession = nil
                } else {
                    // Connection failed or unexpected state — preserve
                    // the error after the transient session is closed.
                    quickLaunchErrorMessage = session.connectionVM.errorMessage
                        ?? "Unable to connect to \(connectionServer.name)."
                    await sessionManager.closeSession(id: session.id)
                    connectingSession = nil
                }
            }
        } else {
            // Show ConnectView for credential entry
            selectedServer = connectionServer
        }
    }

    private func connectionServer(from server: Server, tmuxOverride: String?) -> Server {
        let copy = Server(
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            useMosh: server.useMosh,
            tmuxSession: tmuxOverride ?? server.tmuxSession
        )
        copy.id = server.id
        copy.lastConnected = server.lastConnected
        return copy
    }

    private func deleteServer(_ server: Server) {
        KeychainService.shared.deletePassword(forServer: server.id)
        modelContext.delete(server)
    }

    private func duplicateServer(_ server: Server) {
        let duplicatedServer = Server(
            name: duplicatedServerName(from: server.name),
            hostname: server.hostname,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            useMosh: server.useMosh,
            tmuxSession: server.tmuxSession
        )

        if server.authMethod == .password,
           let password = try? KeychainService.shared.retrievePassword(forServer: server.id) {
            try? KeychainService.shared.storePassword(password, forServer: duplicatedServer.id)
        }

        modelContext.insert(duplicatedServer)
        HapticService.lightTap()
        editingServer = duplicatedServer
    }

    private func duplicatedServerName(from originalName: String) -> String {
        let baseName = "\(originalName) Copy"
        guard !servers.contains(where: { $0.name == baseName }) else {
            var copyIndex = 2
            while servers.contains(where: { $0.name == "\(baseName) \(copyIndex)" }) {
                copyIndex += 1
            }
            return "\(baseName) \(copyIndex)"
        }
        return baseName
    }
}

/// A row displaying server name, hostname, tmux session, and connection badges.
///
/// Badge color semantics: green = Mosh, blue = SSH, cyan = tmux session name,
/// yellow bolt = stored credentials (quick-launch capable).
struct ServerRow: View {
    let server: Server
    var theme: TerminalTheme = AppearanceSettings.shared.currentTheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 15, weight: .semibold))

                    // tmux session badge — themed cyan
                    if let tmux = server.tmuxSession {
                        Text(tmux)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(SwiftUI.Color(theme.accentCyan))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(SwiftUI.Color(theme.accentCyan).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Technical details in monospace
                Text("\(server.username)@\(server.hostname):\(server.port)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SwiftUI.Color(theme.secondaryForeground))
            }

            Spacer()

            HStack(spacing: 6) {
                // Protocol badge — themed green for Mosh, blue for SSH
                Text(server.useMosh ? "MOSH" : "SSH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(SwiftUI.Color(server.useMosh ? theme.accentGreen : theme.accentBlue))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(SwiftUI.Color(server.useMosh ? theme.accentGreen : theme.accentBlue).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Auth method indicator
                Image(systemName: server.authMethod == .key ? "key.fill" : "lock.fill")
                    .foregroundStyle(SwiftUI.Color(theme.secondaryForeground))
                    .font(.caption)

                // Quick-launch indicator (bolt) or standard chevron
                if ConnectionViewModel.hasStoredCredentials(for: server) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(SwiftUI.Color(theme.accentYellow).opacity(0.7))
                        .font(.caption)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(SwiftUI.Color(theme.secondaryForeground))
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ServerListView()
        .modelContainer(for: Server.self, inMemory: true)
}
