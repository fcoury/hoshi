import SwiftUI
import SwiftData

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
    @State private var showMaxSessionsAlert = false

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
            get: {
                guard let session = connectingSession else { return false }
                return session.connectionVM.showError && !quickLaunching
            },
            set: { if !$0 {
                connectingSession?.connectionVM.showError = false
                connectingSession?.connectionVM.errorMessage = nil
            }}
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = connectingSession?.connectionVM.errorMessage {
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
            Text("Add a server to get started.")
        } actions: {
            Button("Add Server") {
                showAddServer = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var serverList: some View {
        List {
            // Active sessions carousel
            if sessionManager.hasActiveSessions {
                Section {
                    SessionCarouselView(
                        sessions: sessionManager.sessions,
                        onTap: { sessionID in
                            sessionManager.switchTo(sessionID: sessionID)
                        },
                        onClose: { sessionID in
                            Task {
                                await sessionManager.closeSession(id: sessionID)
                            }
                        }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Server list
            ForEach(servers) { server in
                ServerRow(server: server)
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

                        Button(role: .destructive) {
                            deleteServer(server)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteServer(server)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            editingServer = server
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
    }

    // Create a session and connect — sequential flow avoids race conditions
    private func connectToServer(_ server: Server) {
        guard let session = sessionManager.createSession(for: server) else {
            showMaxSessionsAlert = true
            return
        }

        connectingSession = session

        if ConnectionViewModel.hasStoredCredentials(for: server) {
            // Quick-launch: await full connection, then transition
            quickLaunching = true
            Task {
                await session.connectionVM.quickLaunch(server: server)
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
                    // Connection failed or unexpected state — clean up
                    await sessionManager.closeSession(id: session.id)
                    connectingSession = nil
                }
            }
        } else {
            // Show ConnectView for credential entry
            selectedServer = server
        }
    }

    private func deleteServer(_ server: Server) {
        KeychainService.shared.deletePassword(forServer: server.id)
        modelContext.delete(server)
    }
}

// A row displaying server name, hostname, tmux session, and connection badges
struct ServerRow: View {
    let server: Server

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.headline)

                    // tmux session badge
                    if let tmux = server.tmuxSession {
                        Text(tmux)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(SwiftUI.Color.cyan.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Text("\(server.username)@\(server.hostname):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Mosh badge
            if server.useMosh {
                Text("MOSH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(SwiftUI.Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Auth method indicator
            Image(systemName: server.authMethod == .key ? "key.fill" : "lock.fill")
                .foregroundStyle(.secondary)
                .font(.caption)

            // Quick-launch indicator (bolt) or standard chevron
            if ConnectionViewModel.hasStoredCredentials(for: server) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow.opacity(0.7))
                    .font(.caption)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ServerListView()
        .modelContainer(for: Server.self, inMemory: true)
}
