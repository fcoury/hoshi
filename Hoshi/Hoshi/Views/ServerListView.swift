import SwiftUI
import SwiftData

struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Server.lastConnected, order: .reverse) private var servers: [Server]

    @State private var showAddServer = false
    @State private var selectedServer: Server?
    @State private var editingServer: Server?
    @State private var connectionVM = ConnectionViewModel()
    @State private var quickLaunching = false

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
            .sheet(item: $editingServer) { server in
                AddServerView(existingServer: server)
            }
            .sheet(item: $selectedServer) { server in
                ConnectView(server: server, connectionVM: connectionVM)
            }
            // tmux session picker — shown after SSH connects, before terminal opens
            .sheet(isPresented: Binding(
                get: { connectionVM.showTmuxPicker },
                set: { connectionVM.showTmuxPicker = $0 }
            )) {
                TmuxSessionPickerView(
                    sessions: connectionVM.detectedTmuxSessions
                ) { choice in
                    Task {
                        await connectionVM.completeTmuxChoice(choice, modelContext: modelContext)
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: {
                    // Keep the terminal open during connected, reconnecting, and disconnected states
                    // (disconnected here means the session dropped but we may reconnect)
                    switch connectionVM.connectionState {
                    case .connected, .reconnecting:
                        return true
                    case .disconnected:
                        // Only show terminal if a session object still exists (awaiting reconnect)
                        return connectionVM.hasActiveSession
                    default:
                        return false
                    }
                },
                set: { if !$0 { Task { await connectionVM.disconnect() } } }
            )) {
                TerminalView(connectionVM: connectionVM)
            }
        }
        // Quick-launch error alert — shown if auto-connect fails
        .alert("Connection Failed", isPresented: Binding(
            get: { connectionVM.showError && !quickLaunching },
            set: { if !$0 { connectionVM.showError = false; connectionVM.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = connectionVM.errorMessage {
                Text(error)
            }
        }
        // Quick-launch connecting overlay
        .overlay {
            if quickLaunching {
                ZStack {
                    SwiftUI.Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(connectionVM.connectionPhase.isEmpty
                             ? "Connecting..."
                             : connectionVM.connectionPhase)
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
            // When app returns to foreground, check session health and reconnect if needed
            if newPhase == .active {
                connectionVM.handleSceneActive()
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
            ForEach(servers) { server in
                ServerRow(server: server)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Quick-launch if stored credentials are available
                        if ConnectionViewModel.hasStoredCredentials(for: server) {
                            quickLaunching = true
                            Task {
                                await connectionVM.quickLaunch(server: server)
                                quickLaunching = false
                            }
                        } else {
                            selectedServer = server
                        }
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
