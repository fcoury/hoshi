import SwiftUI
import SwiftData

/// Adaptive server catalog and session manager: a focused phone list or a persistent iPad sidebar.
struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Server.lastConnected, order: .reverse) private var servers: [Server]

    @State private var showAddServer = false
    @State private var selectedServer: Server?
    @State private var editingServer: Server?
    @State private var duplicatingServer: Server?
    @State private var serverPendingDeletion: Server?
    @State private var sessionPendingClosure: ManagedSession?
    @State private var showSettings = false
    @State private var showAgentInbox = false
    @State private var selectedInboxEvent: AgentInboxEvent?
    @State private var searchText = ""

    @State private var sessionManager = SessionManager(agentEventCenter: .shared)
    @State private var quickLaunching = false
    @State private var connectingSession: ManagedSession?
    @State private var quickLaunchError: ErrorPresentation?
    @State private var showMaxSessionsAlert = false
    @State private var splitViewVisibility = NavigationSplitViewVisibility.all

    private let appearance = AppearanceSettings.shared
    private let agentEvents = AgentEventCenter.shared
    private let deepLinks = AgentDeepLinkRouter.shared
    private var theme: TerminalTheme { appearance.currentTheme }
    private var usesSplitView: Bool { horizontalSizeClass == .regular }
    private var catalog: ServerCatalog {
        ServerCatalog(servers: servers, searchText: searchText)
    }

    var body: some View {
        navigationRoot
            .sheet(isPresented: $showAddServer) {
                AddServerView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showAgentInbox, onDismiss: openSelectedInboxEvent) {
                AgentInboxView { event in
                    selectedInboxEvent = event
                    showAgentInbox = false
                }
            }
            .sheet(item: $editingServer) { server in
                AddServerView(existingServer: server)
            }
            .sheet(item: $duplicatingServer) { server in
                AddServerView(
                    duplicatedServer: server,
                    suggestedName: ServerCatalog.duplicatedName(
                        from: server.name,
                        existingNames: servers.map(\.name)
                    )
                )
            }
            .sheet(item: $selectedServer, onDismiss: finishCredentialSheet) { server in
                if let session = connectingSession {
                    ConnectView(server: server, connectionVM: session.connectionVM)
                }
            }
            .sheet(item: $sessionManager.tmuxPickerSession) { session in
                tmuxPicker(for: session)
            }
            .fullScreenCover(item: Binding<ManagedSession?>(
                get: { usesSplitView ? nil : sessionManager.activeSession },
                set: { if $0 == nil, !usesSplitView { sessionManager.returnToServerList() } }
            )) { session in
                terminalView(for: session)
            }
            .confirmationDialog(
                "Delete Server?",
                isPresented: Binding(
                    get: { serverPendingDeletion != nil },
                    set: { if !$0 { serverPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: serverPendingDeletion
            ) { server in
                Button("Delete \(server.name)", role: .destructive) {
                    deleteServer(server)
                }
                Button("Cancel", role: .cancel) {}
            } message: { server in
                Text("This removes \(server.name) and its saved password. Active sessions are closed.")
            }
            .confirmationDialog(
                "Close Terminal Session?",
                isPresented: Binding(
                    get: { sessionPendingClosure != nil },
                    set: { if !$0 { sessionPendingClosure = nil } }
                ),
                titleVisibility: .visible,
                presenting: sessionPendingClosure
            ) { session in
                Button("Close \(session.serverName)", role: .destructive) {
                    Task { await sessionManager.closeSession(id: session.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The remote connection will be closed. tmux sessions remain available on the server.")
            }
            .alert("Session Limit Reached", isPresented: $showMaxSessionsAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can have up to \(SessionManager.maxSessions) active sessions. Close an existing session to open a new one.")
            }
            .alert(quickLaunchError?.title ?? "Unable to Complete Action", isPresented: Binding(
                get: { quickLaunchError != nil },
                set: { if !$0 { quickLaunchError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(quickLaunchError?.fullMessage ?? "")
            }
            .overlay {
                if quickLaunching, let session = connectingSession {
                    connectingOverlay(for: session)
                }
            }
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
            .onChange(of: deepLinks.pendingRoute) { _, route in
                guard let route else { return }
                handleAgentRoute(route)
                deepLinks.clear()
            }
            .onAppear {
                if let route = deepLinks.pendingRoute {
                    handleAgentRoute(route)
                    deepLinks.clear()
                }
            }
            .task(id: servers.map(\.id)) {
                await restorePersistedSessions()
            }
            .overlay {
                if scenePhase != .active {
                    Color(theme.background)
                        .ignoresSafeArea()
                }
            }
            .hostKeyTrustPrompt(enabled: selectedServer == nil)
    }

    @ViewBuilder
    private var navigationRoot: some View {
        if usesSplitView {
            NavigationSplitView(columnVisibility: $splitViewVisibility) {
                sidebar
                    .navigationTitle("Hoshi")
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 460)
                    .toolbar { navigationToolbar }
                    .toolbarBackground(Color(theme.chromeSurface), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(theme.isLight ? .light : .dark, for: .navigationBar)
            } detail: {
                if let session = sessionManager.activeSession {
                    terminalView(for: session)
                } else {
                    ContentUnavailableView {
                        Label("Select a Server", systemImage: "terminal")
                    } description: {
                        Text("Connect to a server or reopen an active session.")
                    }
                    .foregroundStyle(Color(theme.foreground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(theme.background))
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                Group {
                    if servers.isEmpty {
                        emptyState
                    } else if catalog.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        serverList
                    }
                }
                .background(Color(theme.chromeBackground))
                .navigationTitle("Hoshi")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Search servers")
                .modifier(MinimizedSearchToolbarModifier())
                .toolbar { navigationToolbar }
                .toolbarBackground(Color(theme.chromeSurface), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(theme.isLight ? .light : .dark, for: .navigationBar)
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showAgentInbox = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "tray.full")
                    if agentEvents.unreadCount > 0 {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 5, y: -4)
                    }
                }
            }
            .accessibilityLabel("Agent inbox, \(agentEvents.unreadCount) unread")
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button {
                showAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("$ add a server to get started")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        } actions: {
            Button("Add Server") {
                showAddServer = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var sidebar: some View {
        List {
            if sessionManager.hasActiveSessions {
                Section("Active Sessions") {
                    ForEach(sessionManager.sessions) { session in
                        sessionButton(session)
                    }
                }
            }

            sidebarSection("Servers", systemImage: "server.rack", servers: catalog.ordered)

            if catalog.isEmpty && !servers.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(theme.chromeBackground))
        .searchable(text: $searchText, prompt: "Search servers")
        .overlay {
            if servers.isEmpty && !sessionManager.hasActiveSessions {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, systemImage: String, servers: [Server]) -> some View {
        if !servers.isEmpty {
            Section {
                ForEach(servers) { server in
                    serverButton(server)
                }
            } header: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private var serverList: some View {
        List {
            if sessionManager.hasActiveSessions {
                Section {
                    ForEach(sessionManager.sessions) { session in
                        sessionButton(session)
                            .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 8))
                            .listRowBackground(Color(theme.chromeBackground))
                            .listRowSeparatorTint(Color(theme.separator))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    sessionPendingClosure = session
                                } label: {
                                    Label("Close", systemImage: "xmark.circle")
                                }

                                Button {
                                    duplicateSession(id: session.id)
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                .tint(Color(theme.accentBlue))
                            }
                    }
                } header: {
                    sectionHeader("ACTIVE SESSIONS (\(sessionManager.sessions.count))")
                }
            }

            Section {
                ForEach(catalog.ordered) { server in
                    serverButton(server)
                        .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 8))
                        .listRowBackground(Color(theme.chromeBackground))
                        .listRowSeparatorTint(Color(theme.separator))
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                toggleFavorite(server)
                            } label: {
                                Label(
                                    server.isFavorite ? "Unfavorite" : "Favorite",
                                    systemImage: server.isFavorite ? "star.slash" : "star.fill"
                                )
                            }
                            .tint(Color(theme.accentYellow))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                serverPendingDeletion = server
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editingServer = server
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Color(theme.accentBlue))
                        }
                }
            } header: {
                sectionHeader("SERVERS")
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .background(Color(theme.chromeBackground))
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(Color(theme.secondaryForeground))

            Rectangle()
                .fill(Color(theme.separator))
                .frame(height: 0.5)
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }

    private func serverButton(_ server: Server) -> some View {
        HStack(spacing: 2) {
            Button {
                connectToServer(server)
            } label: {
                ServerRow(server: server, theme: theme)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                serverActions(for: server)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color(theme.secondaryForeground))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Actions for \(server.name)")
        }
        .contextMenu { serverActions(for: server) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(server.isFavorite ? "Remove Favorite" : "Add Favorite")) {
            toggleFavorite(server)
        }
        .accessibilityAction(named: Text("Edit Server")) {
            editingServer = server
        }
        .accessibilityAction(named: Text("Delete Server")) {
            serverPendingDeletion = server
        }
    }

    private func sessionButton(_ session: ManagedSession) -> some View {
        HStack(spacing: 2) {
            Button {
                HapticService.mediumTap()
                sessionManager.switchTo(sessionID: session.id)
            } label: {
                SessionRowView(session: session)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Reopens the active terminal session")

            SessionActionsMenu(
                session: session,
                onDuplicate: duplicateSession,
                onClose: { id in
                    sessionPendingClosure = sessionManager.sessions.first { $0.id == id }
                }
            )
        }
        .contextMenu {
            Button {
                duplicateSession(id: session.id)
            } label: {
                Label("Duplicate Session", systemImage: "plus.square.on.square")
            }

            Button(role: .destructive) {
                sessionPendingClosure = session
            } label: {
                Label("Close Session", systemImage: "xmark.circle")
            }
        }
    }

    @ViewBuilder
    private func serverActions(for server: Server) -> some View {
        Button {
            toggleFavorite(server)
        } label: {
            Label(
                server.isFavorite ? "Remove Favorite" : "Add Favorite",
                systemImage: server.isFavorite ? "star.slash" : "star"
            )
        }

        Button {
            editingServer = server
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Button {
            HapticService.lightTap()
            duplicatingServer = server
        } label: {
            Label("Duplicate Server", systemImage: "doc.on.doc")
        }

        Button(role: .destructive) {
            serverPendingDeletion = server
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func tmuxPicker(for session: ManagedSession) -> some View {
        TmuxSessionPickerView(
            sessions: session.connectionVM.detectedTmuxSessions,
            onRefresh: {
                Task { await session.connectionVM.refreshTmuxSessions() }
            }
        ) { choice in
            Task {
                let tmuxName = await session.connectionVM.completeTmuxChoice(choice)
                if case .cancel = choice {
                    sessionManager.tmuxPickerSession = nil
                    await sessionManager.closeSession(id: session.id)
                    return
                }

                guard session.connectionVM.connectionState == .connected else {
                    quickLaunchError = session.connectionVM.presentedError ?? ErrorPresentation.classify(
                        ErrorMessageFailure(message: "Unable to start the selected terminal session."),
                        context: .connection(server: session.server, operation: .tmux)
                    )
                    sessionManager.tmuxPickerSession = nil
                    await sessionManager.closeSession(id: session.id)
                    return
                }

                session.tmuxSession = tmuxName
                recordSuccessfulConnection(session)
                sessionManager.recordSessionUpdate(session)
                sessionManager.tmuxPickerSession = nil
                sessionManager.switchTo(sessionID: session.id)
            }
        }
    }

    private func terminalView(for session: ManagedSession) -> some View {
        TerminalView(
            connectionVM: session.connectionVM,
            managedSession: session,
            sessions: sessionManager.sessions,
            canSwapSession: sessionManager.sessions.count >= 2,
            onSwapSession: { sessionManager.switchToPrevious() },
            onSelectSession: { sessionManager.switchTo(sessionID: $0) },
            onAlwaysUseSSH: { try preferSSH(for: session) },
            onDismiss: { sessionManager.returnToServerList() }
        )
    }

    private func connectingOverlay(for session: ManagedSession) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(session.connectionVM.connectionPhase.isEmpty
                    ? "Connecting..."
                    : session.connectionVM.connectionPhase)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    session.connectionVM.cancelConnection()
                    quickLaunching = false
                    connectingSession = nil
                    Task { await sessionManager.closeSession(id: session.id) }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
        .accessibilityElement(children: .contain)
    }

    private func finishCredentialSheet() {
        guard let session = connectingSession else { return }

        if session.connectionVM.showTmuxPicker {
            persistSelectedSSHKey(for: session)
            session.connectionVM.showTmuxPicker = false
            sessionManager.tmuxPickerSession = session
            connectingSession = nil
        } else if session.connectionVM.connectionState == .connected {
            persistSelectedSSHKey(for: session)
            recordSuccessfulConnection(session)
            sessionManager.switchTo(sessionID: session.id)
            connectingSession = nil
        } else {
            Task { await sessionManager.closeSession(id: session.id) }
            connectingSession = nil
        }
    }

    private func connectToServer(_ server: Server) {
        HapticService.lightTap()
        launchSession(for: server)
    }

    private func duplicateSession(id: UUID) {
        HapticService.lightTap()

        guard let sourceSession = sessionManager.sessions.first(where: { $0.id == id }) else { return }
        guard let sourceServer = servers.first(where: { $0.id == sourceSession.serverID }) else {
            quickLaunchError = ErrorPresentation.classify(
                ErrorMessageFailure(
                    message: "Unable to duplicate \(sourceSession.serverName) because its server profile no longer exists."
                )
            )
            return
        }

        launchSession(for: sourceServer, tmuxOverride: sourceSession.tmuxSession)
    }

    private func launchSession(for server: Server, tmuxOverride: String? = nil) {
        quickLaunchError = nil
        let connectionServer = connectionServer(from: server, tmuxOverride: tmuxOverride)

        guard let session = sessionManager.createSession(for: connectionServer) else {
            selectedServer = nil
            showMaxSessionsAlert = true
            return
        }

        session.tmuxSession = connectionServer.tmuxSession
        connectingSession = session

        if ConnectionViewModel.hasStoredCredentials(for: connectionServer) {
            quickLaunching = true
            Task {
                await session.connectionVM.quickLaunch(server: connectionServer)
                quickLaunching = false

                if session.connectionVM.showTmuxPicker {
                    session.connectionVM.showTmuxPicker = false
                    sessionManager.tmuxPickerSession = session
                    connectingSession = nil
                } else if session.connectionVM.connectionState == .connected {
                    recordSuccessfulConnection(session)
                    sessionManager.switchTo(sessionID: session.id)
                    connectingSession = nil
                } else {
                    quickLaunchError = session.connectionVM.presentedError ?? ErrorPresentation.classify(
                        ErrorMessageFailure(message: "Unable to connect to \(connectionServer.name)."),
                        context: .connection(server: connectionServer)
                    )
                    await sessionManager.closeSession(id: session.id)
                    connectingSession = nil
                }
            }
        } else {
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
            keyID: server.keyID,
            useMosh: server.useMosh,
            isFavorite: server.isFavorite,
            tmuxSession: tmuxOverride ?? server.tmuxSession,
            transportPolicy: server.transportPolicy,
            tmuxPolicy: server.tmuxPolicy,
            moshServerPath: server.moshServerPath,
            moshUDPPortRange: server.moshUDPPortRange,
            remoteClipboardReadPolicy: server.remoteClipboardReadPolicy,
            remoteClipboardWritePolicy: server.remoteClipboardWritePolicy
        )
        copy.id = server.id
        copy.lastConnected = server.lastConnected
        return copy
    }

    private func toggleFavorite(_ server: Server) {
        server.isFavorite.toggle()
        saveServerChanges()
    }

    private func deleteServer(_ server: Server) {
        do {
            try KeychainService.shared.deletePassword(forServer: server.id)
            let activeSessions = sessionManager.sessions.filter { $0.serverID == server.id }
            for session in activeSessions {
                Task { await sessionManager.closeSession(id: session.id) }
            }
            modelContext.delete(server)
            try modelContext.save()
        } catch {
            quickLaunchError = ErrorPresentation.classify(
                error,
                context: .connection(server: server, operation: .credentials)
            )
        }
    }

    private func recordSuccessfulConnection(_ session: ManagedSession) {
        guard let server = servers.first(where: { $0.id == session.serverID }) else { return }
        server.lastConnected = Date()

        if server.tmuxPolicy == .autoAttachLast, let tmuxName = session.tmuxSession {
            server.tmuxSession = tmuxName
        }
        saveServerChanges()
    }

    private func saveServerChanges() {
        do {
            try modelContext.save()
        } catch {
            quickLaunchError = ErrorPresentation.classify(error)
        }
    }

    private func persistSelectedSSHKey(for session: ManagedSession) {
        guard let keyID = session.connectionVM.selectedSSHKeyID,
              let server = servers.first(where: { $0.id == session.serverID }),
              server.authMethod == .key else {
            return
        }
        server.keyID = keyID
        saveServerChanges()
    }

    private func preferSSH(for session: ManagedSession) throws {
        guard let server = servers.first(where: { $0.id == session.serverID }) else {
            throw SessionTransportPreferenceError.serverProfileUnavailable(session.serverName)
        }

        try sessionManager.preferSSH(for: session, persistedServer: server) {
            try modelContext.save()
        }
    }

    private func restorePersistedSessions() async {
        let restoredSessions = sessionManager.restoreSessions(using: servers)
        for session in restoredSessions {
            guard ConnectionViewModel.hasStoredCredentials(for: session.server) else { continue }

            await session.connectionVM.quickLaunch(server: session.server)
            if session.connectionVM.showTmuxPicker {
                let choice: TmuxChoice
                if let sessionName = session.tmuxSession,
                   let existing = session.connectionVM.detectedTmuxSessions.first(where: { $0.name == sessionName }) {
                    choice = .attach(existing)
                } else {
                    choice = .skip
                }
                _ = await session.connectionVM.completeTmuxChoice(choice)
            }
            sessionManager.recordSessionUpdate(session)
        }
    }

    private func openSelectedInboxEvent() {
        guard let event = selectedInboxEvent else { return }
        selectedInboxEvent = nil

        if let sessionID = event.sessionID,
           sessionManager.sessions.contains(where: { $0.id == sessionID }) {
            sessionManager.switchTo(sessionID: sessionID)
            return
        }

        if let serverID = event.serverID,
           let server = servers.first(where: { $0.id == serverID }) {
            connectToServer(server)
        }
    }

    private func handleAgentRoute(_ route: AgentDeepLink) {
        switch route {
        case .inbox(let eventID):
            if let eventID {
                agentEvents.markRead(eventID: eventID)
            }
            showAgentInbox = true
        case .session(let sessionID, let eventID):
            if let eventID {
                agentEvents.markRead(eventID: eventID)
            }
            if sessionManager.sessions.contains(where: { $0.id == sessionID }) {
                sessionManager.switchTo(sessionID: sessionID)
            } else {
                showAgentInbox = true
            }
        case .server(let serverID, let eventID):
            if let eventID {
                agentEvents.markRead(eventID: eventID)
            }
            if let server = servers.first(where: { $0.id == serverID }) {
                connectToServer(server)
            } else {
                showAgentInbox = true
            }
        }
    }
}

/// A keyboard-accessible server row with explicit theme colors and connection metadata.
struct ServerRow: View {
    let server: Server
    var theme: TerminalTheme = AppearanceSettings.shared.currentTheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.useMosh ? "antenna.radiowaves.left.and.right" : "terminal")
                .font(.body.weight(.medium))
                .foregroundStyle(transportColor)
                .frame(width: 38, height: 38)
                .background(transportColor.opacity(0.12), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if server.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Color(theme.accentYellow))
                            .accessibilityLabel("Favorite")
                    }

                    Text(server.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(theme.foreground))
                        .lineLimit(1)

                    if let tmux = server.tmuxSession {
                        Text(tmux)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color(theme.accentCyan))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color(theme.accentCyan).opacity(0.15), in: .rect(cornerRadius: 4))
                            .lineLimit(1)
                    }
                }

                Text(verbatim: server.loginEndpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(theme.secondaryForeground))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(server.transportPolicy.displayName.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(transportColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(transportColor.opacity(0.14), in: .rect(cornerRadius: 5))
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Connects to \(server.hostname)")
    }

    private var transportColor: Color {
        Color(server.useMosh ? theme.accentGreen : theme.accentBlue)
    }

    private var accessibilityLabel: String {
        var components = [
            server.isFavorite ? "Favorite" : nil,
            server.name,
            server.loginEndpoint,
            server.transportPolicy.displayName,
        ].compactMap { $0 }
        if let tmux = server.tmuxSession {
            components.append("tmux \(tmux)")
        }
        return components.joined(separator: ", ")
    }
}

private struct MinimizedSearchToolbarModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.searchToolbarBehavior(.minimize)
        } else {
            content
        }
    }
}

#Preview {
    ServerListView()
        .modelContainer(for: Server.self, inMemory: true)
}
