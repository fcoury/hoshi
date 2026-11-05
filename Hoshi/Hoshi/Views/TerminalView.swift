import SwiftUI
import UIKit
import SwiftData
import Citadel
import NIOCore

/// Full-screen terminal emulator view wrapping a Ghostty Metal surface.
///
/// Owns the status bar, connection banners, keyboard toolbar lifecycle,
/// and pinch-to-zoom font sizing. Delegates actual terminal rendering
/// to `GhosttyTerminalView`.
///
/// Connection state drives three visual behaviors:
/// - **Status dot** pulses during transient states (connecting, reconnecting).
/// - **Banners** slide in as floating pills for reconnecting/disconnected states.
/// - **Haptic feedback** fires on every state transition (success, warning, error).
///
/// The view auto-dismisses only when the remote shell exits normally. Recoverable
/// connection failures stay on-screen so the user can retry without losing context.
struct TerminalView: View {
    @Bindable var connectionVM: ConnectionViewModel
    var managedSession: ManagedSession?
    var sessions: [ManagedSession] = []
    var canSwapSession: Bool = false
    var onSwapSession: (() -> Void)?
    var onSelectSession: ((UUID) -> Void)?
    var onAlwaysUseSSH: (() throws -> Void)?
    var onOpenHerdr: ((HerdrAttachment) -> Void)?
    var onDismiss: (() -> Void)?
    /// True when shown full-screen over the server list, which then can't present
    /// host-key prompts (e.g. a reconnect that meets a new key).
    var presentsHostKeyPrompts = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appearanceSettings = AppearanceSettings.shared
    private let keyProfiles = KeyProfileStore.shared
    private let voiceSettings = VoicePromptSettings.shared

    // Font size state for pinch-to-zoom (initialized from settings)
    @State private var fontSize: CGFloat = AppearanceSettings.shared.fontSize

    // Toolbar edit sheet
    @State private var showToolbarEditor = false
    // Key set the editor edits; frozen while the editor is open.
    @State private var editingKeyProfileID: String?
    @State private var showTmuxPalette = false
    @State private var showVoiceComposer = false
    @State private var showFileUploader = false
    @State private var showFileBrowser = false
    @State private var showSessionPicker = false
    @State private var showHerdrAgents = false
    @State private var keyboardVisibleBeforeHerdrAgents = true

    // Keyboard visibility for explicit show/hide control
    @State private var isKeyboardVisible = true
    @State private var keyboardVisibleBeforeToolbarEditor = true
    @State private var keyboardVisibleBeforeTmuxPalette = true
    @State private var keyboardVisibleBeforeVoiceComposer = true
    @State private var keyboardVisibleBeforeFileUploader = true
    @State private var keyboardVisibleBeforeFileBrowser = true
    @State private var keyboardVisibleBeforeSessionPicker = true

    // Unsafe pastes and remote clipboard requests require explicit approval.
    @State private var pendingClipboardRequest: TerminalClipboardRequest?
    @State private var queuedClipboardRequests: [TerminalClipboardRequest] = []
    @State private var keyboardVisibleBeforeClipboardPrompt = false
    @State private var clipboardNotice: TerminalClipboardNotice?
    @State private var clipboardNoticeDismissal: Task<Void, Never>?

    // Status dot pulse animation for connecting/reconnecting states
    @State private var statusDotPulsing = false

    // Header collapses to a slim strip while typing to give rows back to the terminal.
    @State private var isHeaderCollapsed = false

    // Server name from whichever session is active
    private var serverName: String {
        connectionVM.moshSession?.server.name
            ?? connectionVM.sshSession?.server.name
            ?? "Terminal"
    }

    private var serverDetail: String {
        let server = connectionVM.moshSession?.server ?? connectionVM.sshSession?.server
        guard let server else { return "" }
        return "\(server.username)@\(server.hostname)"
    }

    private var isMosh: Bool {
        connectionVM.moshSession != nil
    }

    var body: some View {
        alertedTerminal
            .hostKeyTrustPrompt(enabled: presentsHostKeyPrompts && scenePhase == .active)
            .overlay {
                if scenePhase != .active {
                    privacyCover
                }
            }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            Group {
                if isHeaderCollapsed {
                    compactStatusBar
                        .transition(.opacity)
                } else {
                    statusBar
                        .transition(.opacity)
                }
            }

            GhosttyTerminalView(
                connectionVM: connectionVM,
                managedSession: managedSession,
                appearanceSettings: appearanceSettings,
                fontSize: $fontSize,
                showToolbarEditor: $showToolbarEditor,
                showVoiceComposer: $showVoiceComposer,
                showFileUploader: $showFileUploader,
                keyboardVisible: $isKeyboardVisible,
                voicePromptsEnabled: voiceSettings.isEnabled,
                onClipboardRequest: enqueueClipboardRequest,
                onClipboardNotice: presentClipboardNotice,
                onSwapSession: canSwapSession ? onSwapSession : nil,
                onUserInput: handleUserInput,
                keyProfileButtons: activeKeyProfile.resolvedKeys,
                keyProfileChip: KeyProfileChip(
                    active: activeKeyProfile,
                    pinnedID: keyProfiles.pinnedProfileID(for: currentServer?.id),
                    profiles: keyProfiles.profiles
                ),
                onSelectKeyProfile: { profileID in
                    keyProfiles.pin(profileID, for: currentServer?.id)
                },
                onSurfaceReady: { surfaceView in
                    managedSession?.surfaceView = surfaceView
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Breathing room so glyphs don't touch the screen edge.
            .padding(.horizontal, Self.terminalHorizontalInset)
            .overlay(alignment: .top) {
                terminalNoticeStack
            }
            .overlay(alignment: .bottomTrailing) {
                if managedSession?.isScrolledBack == true {
                    jumpToBottomButton
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Header, terminal and toolbar share one surface: no tonal bands.
        .background(SwiftUI.Color(appearanceSettings.currentTheme.background))
    }

    private static let terminalHorizontalInset: CGFloat = 6

    private var animatedTerminal: some View {
        terminalContent
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: connectionVM.connectionState)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: connectionVM.recoveryStatus)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: connectionVM.transportFallbackNotice?.id)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: clipboardNotice?.id)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHeaderCollapsed)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: managedSession?.isScrolledBack)
            .onChange(of: isKeyboardVisible) { _, visible in
                if !visible { expandHeader() }
            }
            .onChange(of: managedSession?.id) { _, _ in
                expandHeader()
            }
            .onChange(of: appearanceSettings.autoHideTerminalHeader) { _, enabled in
                if !enabled { expandHeader() }
            }
            .onChange(of: fontSize) { _, newSize in
                appearanceSettings.fontSize = newSize
            }
            .onChange(of: connectionVM.transportFallbackNotice?.id) { _, noticeID in
                if noticeID != nil {
                    HapticService.warning()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    cancelClipboardRequests()
                    clipboardNotice = nil
                    clipboardNoticeDismissal?.cancel()
                }
            }
            .onChange(of: connectionVM.connectionState) { oldState, newState in
                handleConnectionStateChange(from: oldState, to: newState)
            }
    }

    private var observedTerminal: some View {
        animatedTerminal
            .onChange(of: connectionVM.recoveryStatus) { oldStatus, newStatus in
                handleRecoveryStatusChange(from: oldStatus, to: newStatus)
            }
            .onChange(of: showToolbarEditor) { _, isPresented in
                if isPresented {
                    editingKeyProfileID = activeKeyProfile.id
                    keyboardVisibleBeforeToolbarEditor = isKeyboardVisible
                } else if keyboardVisibleBeforeToolbarEditor {
                    isKeyboardVisible = true
                }
            }
            .onChange(of: showTmuxPalette) { _, isPresented in
                if isPresented {
                    keyboardVisibleBeforeTmuxPalette = isKeyboardVisible
                } else if keyboardVisibleBeforeTmuxPalette {
                    isKeyboardVisible = true
                }
            }
            .onChange(of: showVoiceComposer) { _, isPresented in
                if isPresented {
                    keyboardVisibleBeforeVoiceComposer = isKeyboardVisible
                    isKeyboardVisible = false
                } else {
                    isKeyboardVisible = keyboardVisibleBeforeVoiceComposer
                }
            }
            .onChange(of: showFileUploader) { _, isPresented in
                if isPresented {
                    keyboardVisibleBeforeFileUploader = isKeyboardVisible
                    isKeyboardVisible = false
                } else {
                    isKeyboardVisible = keyboardVisibleBeforeFileUploader
                }
            }
            .onChange(of: showFileBrowser) { _, isPresented in
                if isPresented {
                    keyboardVisibleBeforeFileBrowser = isKeyboardVisible
                    isKeyboardVisible = false
                } else {
                    isKeyboardVisible = keyboardVisibleBeforeFileBrowser
                }
            }
            .onChange(of: showSessionPicker) { _, isPresented in
                if !isPresented, keyboardVisibleBeforeSessionPicker {
                    isKeyboardVisible = true
                }
            }
            .onChange(of: showHerdrAgents) { _, isPresented in
                if isPresented {
                    keyboardVisibleBeforeHerdrAgents = isKeyboardVisible
                    isKeyboardVisible = false
                } else {
                    isKeyboardVisible = keyboardVisibleBeforeHerdrAgents
                }
            }
    }

    private var presentedTerminal: some View {
        observedTerminal
            .sheet(isPresented: $showToolbarEditor) {
                ToolbarEditView(
                    profileID: editingKeyProfileID ?? activeKeyProfile.id,
                    serverName: serverName,
                    herdrConfigLoader: loadHerdrConfig
                )
            }
            .sheet(isPresented: $showTmuxPalette) {
                TmuxCommandPaletteView { bytes in
                    Task { await connectionVM.sendBytes(ArraySlice(bytes)) }
                }
            }
            .sheet(isPresented: $showVoiceComposer) {
                VoicePromptComposerView { data in
                    await connectionVM.send(data)
                }
            }
            .sheet(isPresented: $showFileUploader) {
                FileUploadView(connection: connectionVM) { data in
                    guard connectionVM.canAcceptTerminalInput else { return false }
                    await connectionVM.send(data)
                    return true
                }
            }
            .sheet(isPresented: $showFileBrowser) {
                RemoteFileBrowserView(
                    connection: connectionVM,
                    serverName: serverName,
                    initialDirectory: RemoteFileBrowserPolicy.directory(
                        fromWorkingDirectory: managedSession?.workingDirectory,
                        username: currentServer?.username ?? ""
                    )
                ) { data in
                    guard connectionVM.canAcceptTerminalInput else { return false }
                    await connectionVM.send(data)
                    return true
                }
            }
            .sheet(isPresented: $showHerdrAgents) {
                HerdrAgentsView(connectionVM: connectionVM, onOpenInNewSession: onOpenHerdr)
            }
            .sheet(item: $connectionVM.pendingHerdrReply) { target in
                HerdrReplyView(connectionVM: connectionVM, target: target, onOpenInNewSession: onOpenHerdr)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSessionPicker) {
                TerminalSessionPickerView(
                    sessions: sessions,
                    selectedSessionID: managedSession?.id
                ) { sessionID in
                    onSelectSession?(sessionID)
                }
            }
    }

    private var alertedTerminal: some View {
        presentedTerminal
            .alert(
                pendingClipboardRequest?.kind.title ?? "Confirm Paste",
                isPresented: clipboardAlertIsPresented,
                presenting: pendingClipboardRequest
            ) { request in
                Button("Cancel", role: .cancel) {
                    resolveClipboardRequest(request, approved: false)
                }
                Button(request.kind.confirmButtonTitle) {
                    resolveClipboardRequest(request, approved: true)
                }
                if let server = clipboardServer, canRememberClipboardApproval(for: request.kind, on: server) {
                    Button("Always Allow for \(server.name)") {
                        // Resolve first so a save-failure notice isn't replaced by the "allowed" one.
                        resolveClipboardRequest(request, approved: true)
                        rememberClipboardApproval(for: request.kind, on: server)
                    }
                }
            } message: { request in
                Text(request.message)
            }
            .alert(
                connectionVM.presentedError?.title ?? "Connection Error",
                isPresented: $connectionVM.showError
            ) {
                if let change = connectionVM.presentedError?.hostKeyChange {
                    Button("Forget Old Key and Verify Again", role: .destructive) {
                        do {
                            try change.forgetTrustedKey()
                            HapticService.success()
                            Task { await connectionVM.retryConnection() }
                        } catch {
                            connectionVM.presentConnectionError(error)
                        }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(connectionVM.presentedError?.fullMessage ?? connectionVM.errorMessage ?? "The connection failed.")
            }
    }

    private var clipboardAlertIsPresented: Binding<Bool> {
        Binding(
            get: { pendingClipboardRequest != nil },
            set: { isPresented in
                guard !isPresented, let request = pendingClipboardRequest else { return }
                resolveClipboardRequest(request, approved: false)
            }
        )
    }

    @ViewBuilder
    private var terminalNoticeStack: some View {
        VStack(spacing: 8) {
            if connectionVM.recoveryStatus != .idle {
                ConnectionRecoveryBanner(
                    status: connectionVM.recoveryStatus,
                    isMosh: isMosh,
                    onRetry: {
                        Task { await connectionVM.retryConnection() }
                    },
                    onRestart: isMosh ? {
                        Task { await connectionVM.restartConnection() }
                    } : nil,
                    onDetails: connectionVM.presentRecoveryDetails
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if connectionVM.connectionState == .connected,
               let fallback = connectionVM.transportFallbackNotice {
                TransportFallbackBanner(
                    presentation: fallback,
                    serverName: serverName,
                    onAlwaysUseSSH: connectionVM.canRememberSSHFallback ? onAlwaysUseSSH : nil,
                    onDismiss: connectionVM.dismissTransportFallbackNotice
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let clipboardNotice, scenePhase == .active {
                clipboardNoticeBanner(clipboardNotice)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 620)
        .padding(.top, 8)
        .padding(.horizontal, 12)
    }

    private func clipboardNoticeBanner(_ notice: TerminalClipboardNotice) -> some View {
        Label(notice.message, systemImage: notice.kind.symbolName)
            .font(.subheadline)
            .foregroundStyle(Color(appearanceSettings.currentTheme.foreground))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(notice.message)
            .accessibilityIdentifier("terminal.clipboard.notice")
    }

    private var privacyCover: some View {
        ZStack {
            SwiftUI.Color(appearanceSettings.currentTheme.background)
            Image(systemName: "lock.shield")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityLabel("Terminal contents hidden")
    }

    private func enqueueClipboardRequest(_ request: TerminalClipboardRequest) {
        guard scenePhase == .active, connectionVM.canAcceptTerminalInput else {
            request.onDecision(false)
            return
        }

        guard pendingClipboardRequest == nil else {
            queuedClipboardRequests.append(request)
            return
        }

        keyboardVisibleBeforeClipboardPrompt = isKeyboardVisible
        pendingClipboardRequest = request
    }

    private func resolveClipboardRequest(_ request: TerminalClipboardRequest, approved: Bool) {
        guard pendingClipboardRequest?.id == request.id else { return }
        let shouldRestoreKeyboard = keyboardVisibleBeforeClipboardPrompt
        pendingClipboardRequest = nil
        request.onDecision(approved)

        if !queuedClipboardRequests.isEmpty {
            let nextRequest = queuedClipboardRequests.removeFirst()
            DispatchQueue.main.async {
                enqueueClipboardRequest(nextRequest)
            }
            return
        }

        guard shouldRestoreKeyboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pendingClipboardRequest == nil else { return }
            isKeyboardVisible = true
        }
    }

    private var clipboardServer: Server? {
        managedSession?.server ?? connectionVM.moshSession?.server ?? connectionVM.sshSession?.server
    }

    private func canRememberClipboardApproval(for kind: TerminalClipboardRequestKind, on server: Server) -> Bool {
        switch kind {
        case .remoteRead: server.remoteClipboardReadPolicy != .allow
        case .remoteWrite: server.remoteClipboardWritePolicy != .allow
        case .paste: false
        }
    }

    /// Persists the same per-server policy that Edit Server exposes, so it can be undone there.
    private func rememberClipboardApproval(for kind: TerminalClipboardRequestKind, on server: Server) {
        // Sessions run on a detached copy of the server; update it and the stored record.
        let serverID = server.id
        do {
            let stored = try modelContext.fetch(FetchDescriptor<Server>(predicate: #Predicate { $0.id == serverID })).first
            for target in [server, stored].compactMap({ $0 }) {
                switch kind {
                case .remoteRead: target.remoteClipboardReadPolicy = .allow
                case .remoteWrite: target.remoteClipboardWritePolicy = .allow
                case .paste: return
                }
            }
            try modelContext.save()
        } catch {
            // The detached session copy may already allow it; tell the user it won't survive a reconnect.
            presentClipboardNotice(
                TerminalClipboardNotice(kind: .policySaveFailed, serverName: server.name, byteCount: nil)
            )
        }
    }

    private func cancelClipboardRequests() {
        let activeRequest = pendingClipboardRequest
        let waitingRequests = queuedClipboardRequests
        pendingClipboardRequest = nil
        queuedClipboardRequests.removeAll()
        activeRequest?.onDecision(false)
        for request in waitingRequests {
            request.onDecision(false)
        }
    }

    private func presentClipboardNotice(_ notice: TerminalClipboardNotice) {
        clipboardNoticeDismissal?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            clipboardNotice = notice
        }

        if notice.kind.isWarning {
            HapticService.warning()
        } else {
            HapticService.lightTap()
        }
        UIAccessibility.post(notification: .announcement, argument: notice.message)

        clipboardNoticeDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, clipboardNotice?.id == notice.id else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                clipboardNotice = nil
            }
        }
    }

    private func handleConnectionStateChange(
        from oldState: ConnectionState,
        to newState: ConnectionState
    ) {
        if newState != .connected {
            expandHeader()
        }

        switch newState {
        case .connected:
            HapticService.success()
        case .reconnecting:
            HapticService.warning()
        case .disconnected where oldState == .connected:
            HapticService.error()
        case .error:
            HapticService.error()
        default:
            break
        }

        if oldState == .connected, newState == .disconnected {
            onDismiss?()
        }
    }

    private func handleRecoveryStatusChange(
        from oldStatus: ConnectionRecoveryStatus,
        to newStatus: ConnectionRecoveryStatus
    ) {
        guard oldStatus != newStatus else { return }
        if newStatus != .idle {
            expandHeader()
        }
        if newStatus.blocksInput {
            cancelClipboardRequests()
        }

        switch newStatus {
        case .waitingForNetwork:
            UIAccessibility.post(notification: .announcement, argument: "No network. Waiting to retry.")
        case .reconnecting:
            UIAccessibility.post(notification: .announcement, argument: "Connection interrupted. Reconnecting.")
        case .unavailable:
            UIAccessibility.post(notification: .announcement, argument: "Could not reconnect. Actions are available.")
        case .idle:
            break
        }
    }

    // MARK: - Header context

    private var currentServer: Server? {
        managedSession?.server
            ?? connectionVM.moshSession?.server
            ?? connectionVM.sshSession?.server
    }

    /// Foreground program or directory, e.g. "vim main.rs" or "~/code/hoshi".
    private var contextSubtitle: String? {
        guard connectionVM.connectionState == .connected, let managedSession else { return nil }
        return TerminalHeaderContext.subtitle(
            title: managedSession.terminalTitle,
            workingDirectory: managedSession.workingDirectory,
            username: currentServer?.username ?? "",
            hostname: currentServer?.hostname ?? "",
            serverName: serverName
        )
    }

    private var visibleRoundTripTime: TimeInterval? {
        guard isMosh,
              connectionVM.connectionState == .connected,
              connectionVM.recoveryStatus == .idle else { return nil }
        return connectionVM.roundTripTime
    }

    @ViewBuilder
    private var latencyIndicator: some View {
        if let roundTripTime = visibleRoundTripTime {
            let quality = ConnectionLatencyQuality(roundTripTime: roundTripTime)
            HStack(spacing: 3) {
                Image(systemName: "cellularbars", variableValue: quality.signalLevel)
                    .font(.caption2)
                    .foregroundStyle(latencyColor(quality))
                Text(ConnectionLatencyQuality.displayText(for: roundTripTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .contentTransition(.numericText())
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Latency \(ConnectionLatencyQuality.displayText(for: roundTripTime))")
        }
    }

    private func latencyColor(_ quality: ConnectionLatencyQuality) -> Color {
        let theme = appearanceSettings.currentTheme
        switch quality {
        case .good: return Color(theme.accentGreen)
        case .fair: return Color(theme.accentYellow)
        case .poor: return Color(theme.accentRed)
        }
    }

    // MARK: - Key sets

    private var activeKeyProfile: KeyProfile {
        keyProfiles.resolve(
            title: managedSession?.terminalTitle,
            serverID: currentServer?.id,
            // Sessions attached to Herdr get Herdr keys even when the title doesn't say so.
            attachedID: managedSession?.herdrAttachment != nil ? KeyProfile.herdrID : nil
        )
    }

    /// Reads the connected server's Herdr config.toml (nil when it has none).
    private func loadHerdrConfig() async throws -> String? {
        let output = try await connectionVM.withVerifiedFileTransferClient { client in
            let buffer = try await client.executeCommand(HerdrKeyImport.readConfigCommand)
            return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        }
        return output.contains(HerdrKeyImport.noConfigMarker) ? nil : output
    }

    // MARK: - Auto-hiding header

    private func handleUserInput() {
        guard !isHeaderCollapsed,
              appearanceSettings.autoHideTerminalHeader,
              isKeyboardVisible,
              connectionVM.canAcceptTerminalInput,
              connectionVM.transportFallbackNotice == nil else { return }
        isHeaderCollapsed = true
    }

    private func expandHeader() {
        guard isHeaderCollapsed else { return }
        isHeaderCollapsed = false
    }

    private var compactStatusBar: some View {
        Button {
            HapticService.lightTap()
            expandHeader()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(serverName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(appearanceSettings.currentTheme.foreground))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let contextSubtitle {
                    Text(contextSubtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                latencyIndicator
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(SwiftUI.Color(appearanceSettings.currentTheme.background))
        .simultaneousGesture(
            DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height > 8 { expandHeader() }
            }
        )
        .accessibilityLabel("\(serverName), \(connectionAccessibilityLabel)")
        .accessibilityHint("Shows the full terminal header")
        .accessibilityIdentifier("terminal.header.compact")
    }

    // MARK: - Scrollback

    private var jumpToBottomButton: some View {
        Button {
            HapticService.lightTap()
            managedSession?.surfaceView?.scrollToBottom()
        } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(appearanceSettings.currentTheme.foreground))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: .circle)
                .overlay(
                    Circle().strokeBorder(Color(appearanceSettings.currentTheme.separator), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.bottom, 14)
        .accessibilityLabel("Jump to bottom")
        .accessibilityHint("Scrolls back to the latest terminal output")
        .accessibilityIdentifier("terminal.scroll.bottom")
    }

    private var statusBar: some View {
        HStack(spacing: 2) {
            // Minimize — return to server list while keeping the connection alive.
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Servers")
            .accessibilityHint("Returns to the server list and keeps this terminal session running")
            .accessibilityIdentifier("terminal.minimize")
            .keyboardShortcut("w", modifiers: .command)

            Button(action: presentSessionPicker) {
                HStack(spacing: 8) {
                    statusIndicator
                    sessionIdentity
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("\(serverName), \(connectionAccessibilityLabel)")
            .accessibilityHint(sessions.count > 1 ? "Opens the active session picker" : "Shows the current session")
            .keyboardShortcut("o", modifiers: .command)

            Spacer(minLength: 0)

            supplementalStatusActions

            // The toolbar carries the hide-keyboard key while the keyboard is up,
            // so the header only needs a way to bring it back.
            if !isKeyboardVisible {
                Button {
                    isKeyboardVisible = true
                } label: {
                    Image(systemName: "keyboard")
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Show keyboard")
                .accessibilityHint("Shows the terminal software keyboard")
                .accessibilityIdentifier("terminal.keyboard.toggle")
                .transition(.opacity)
            }
        }
        // Hidden shortcut keeps Cmd-Shift-K toggling in both directions.
        .background {
            Button("") { isKeyboardVisible.toggle() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(SwiftUI.Color(appearanceSettings.currentTheme.background))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isKeyboardVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsConnectionDetail)
        .simultaneousGesture(headerPullGesture)
    }

    /// Once connected, the dot already says "connected"; spell the state out only
    /// while it is changing or broken.
    private var showsConnectionDetail: Bool {
        connectionVM.connectionState != .connected
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .scaleEffect(statusDotPulsing ? 1.3 : 1)
            .opacity(statusDotPulsing ? 0.65 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: statusColor)
            .onChange(of: connectionVM.connectionState.isTransient) { _, _ in
                updateStatusPulse()
            }
            .onAppear(perform: updateStatusPulse)
            .accessibilityHidden(true)
    }

    private var sessionIdentity: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(serverName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(appearanceSettings.currentTheme.foreground))
                    .lineLimit(1)

                if connectionVM.hasActiveSession {
                    Text(isMosh ? "MOSH" : "SSH")
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(transportColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(transportColor.opacity(0.15), in: .rect(cornerRadius: 4))
                        .accessibilityHidden(true)
                }

                latencyIndicator

                if sessions.count > 1 {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .accessibilityHidden(true)
                }
            }

            if !showsConnectionDetail, let contextSubtitle {
                Text(contextSubtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .transition(.opacity)
            }

            if showsConnectionDetail {
                HStack(spacing: 4) {
                    Text(connectionVM.connectionState.conciseLabel)
                        .foregroundStyle(statusColor)
                    if !serverDetail.isEmpty {
                        Text("·")
                        Text(serverDetail)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                .lineLimit(1)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var transportColor: Color {
        Color(isMosh
            ? appearanceSettings.currentTheme.accentGreen
            : appearanceSettings.currentTheme.accentBlue)
    }

    private func updateStatusPulse() {
        guard connectionVM.connectionState.isTransient, !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) {
                statusDotPulsing = false
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            statusDotPulsing = true
        }
    }

    private func presentSessionPicker() {
        guard !sessions.isEmpty else { return }
        keyboardVisibleBeforeSessionPicker = isKeyboardVisible
        isKeyboardVisible = false
        HapticService.lightTap()
        showSessionPicker = true
    }

    private var headerPullGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                switch TerminalHeaderPullAction.resolve(translation: value.translation) {
                case .none:
                    break
                case .showSessions:
                    guard sessions.count > 1 else { return }
                    presentSessionPicker()
                case .minimize:
                    HapticService.mediumTap()
                    onDismiss?()
                }
            }
    }

    /// Keeps every tool one tap away on wide layouts while reserving enough room
    /// for the session identity on narrower phones and split-screen windows.
    private var supplementalStatusActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button {
                    showFileUploader = true
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Upload a file or photo securely")
                .accessibilityHint("Transfers the selected item using verified SSH and SFTP")
                .accessibilityIdentifier("terminal.upload.open")
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button {
                    showFileBrowser = true
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Browse server files securely")
                .accessibilityHint("Opens your remote home folder using verified SSH and SFTP")
                .accessibilityIdentifier("terminal.files.open")
                .keyboardShortcut("f", modifiers: [.command, .shift])

                if voiceSettings.isEnabled {
                    Button {
                        showVoiceComposer = true
                    } label: {
                        Image(systemName: "mic")
                            .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Compose on-device voice prompt")
                    .accessibilityHint("Opens a private push-to-talk draft")
                    .accessibilityIdentifier("terminal.voice.open")
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                }

                Button {
                    showTmuxPalette = true
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Open tmux command palette")
                .keyboardShortcut("p", modifiers: [.command, .shift])

                // Wide layouts must offer Herdr too, or blocked agents become invisible.
                if connectionVM.detectedHerdr != nil {
                    Button {
                        showHerdrAgents = true
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                            .frame(minWidth: 44, minHeight: 44)
                            .overlay(alignment: .topTrailing) {
                                if connectionVM.herdrBlockedCount > 0 {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 9, height: 9)
                                        .offset(x: -9, y: 9)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                    .accessibilityLabel("Herdr agents")
                    .accessibilityValue(connectionVM.herdrBlockedCount > 0
                        ? "\(connectionVM.herdrBlockedCount) waiting"
                        : "")
                    .accessibilityIdentifier("terminal.herdr.open")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!connectionVM.canAcceptTerminalInput)

            Menu {
                Button {
                    showFileUploader = true
                } label: {
                    Label("Upload File or Photo", systemImage: "paperclip")
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button {
                    showFileBrowser = true
                } label: {
                    Label("Browse Server Files", systemImage: "folder")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                if voiceSettings.isEnabled {
                    Button {
                        showVoiceComposer = true
                    } label: {
                        Label("Compose Voice Prompt", systemImage: "mic")
                    }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                }

                Button {
                    showTmuxPalette = true
                } label: {
                    Label("Tmux Commands", systemImage: "rectangle.split.3x1")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                if connectionVM.detectedHerdr != nil {
                    Button {
                        showHerdrAgents = true
                    } label: {
                        let blocked = connectionVM.herdrBlockedCount
                        Label(
                            blocked > 0 ? "Herdr Agents (\(blocked) waiting)" : "Herdr Agents",
                            systemImage: "square.stack.3d.up"
                        )
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color(appearanceSettings.currentTheme.secondaryForeground))
                    .frame(minWidth: 44, minHeight: 44)
                    .overlay(alignment: .topTrailing) {
                        // Herdr agents waiting on an approval or question.
                        if connectionVM.herdrBlockedCount > 0 {
                            Circle()
                                .fill(.orange)
                                .frame(width: 9, height: 9)
                                .offset(x: -9, y: 9)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!connectionVM.canAcceptTerminalInput)
            .accessibilityLabel("Terminal tools")
            .accessibilityValue(connectionVM.herdrBlockedCount > 0
                ? "\(connectionVM.herdrBlockedCount) Herdr agents waiting"
                : "")
            .accessibilityHint("Opens file transfer, voice, tmux, and Herdr actions")
            .accessibilityIdentifier("terminal.tools.open")
        }
    }

    private var statusColor: SwiftUI.Color {
        switch connectionVM.connectionState {
        case .connected: return .green
        case .connecting, .sshBootstrap, .moshStarting: return .yellow
        case .reconnecting: return .orange
        case .disconnected: return .red
        case .error: return .red
        }
    }

    private var connectionAccessibilityLabel: String {
        switch connectionVM.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .sshBootstrap: "Establishing SSH connection"
        case .moshStarting: "Starting Mosh"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case .error: "Connection error"
        }
    }
}

enum TerminalHeaderPullAction: Equatable {
    case none
    case showSessions
    case minimize

    static func resolve(translation: CGSize) -> Self {
        guard translation.height > 0,
              translation.height > abs(translation.width) * 1.25 else {
            return .none
        }
        if translation.height >= 96 {
            return .minimize
        }
        if translation.height >= 30 {
            return .showSessions
        }
        return .none
    }
}

private struct TerminalSessionPickerView: View {
    let sessions: [ManagedSession]
    let selectedSessionID: UUID?
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private var theme: TerminalTheme { AppearanceSettings.shared.currentTheme }

    var body: some View {
        NavigationStack {
            List(sessions) { session in
                Button {
                    onSelect(session.id)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        SessionRowView(session: session)
                        if session.id == selectedSessionID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(theme.accentGreen))
                                .accessibilityLabel("Current session")
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(theme.chromeBackground))
                .listRowSeparatorTint(Color(theme.separator))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(theme.chromeBackground))
            .navigationTitle("Active Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ConnectionRecoveryBanner: View {
    let status: ConnectionRecoveryStatus
    let isMosh: Bool
    let onRetry: () -> Void
    let onRestart: (() -> Void)?
    let onDetails: () -> Void

    private let appearanceSettings = AppearanceSettings.shared

    private var accentColor: SwiftUI.Color {
        switch status {
        case .idle:
            SwiftUI.Color(appearanceSettings.currentTheme.accentGreen)
        case .waitingForNetwork, .reconnecting:
            SwiftUI.Color(appearanceSettings.currentTheme.accentYellow)
        case .unavailable:
            SwiftUI.Color(appearanceSettings.currentTheme.accentRed)
        }
    }

    private var message: String {
        switch status {
        case .idle:
            "Connected"
        case .waitingForNetwork:
            "No network — waiting"
        case .reconnecting:
            "Connection interrupted — retrying"
        case .unavailable:
            "Couldn’t reconnect"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon

                VStack(alignment: .leading, spacing: 1) {
                    Text(message)
                        .font(.caption.weight(.semibold).monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Input paused")
                        .font(.caption2.weight(.medium).monospaced())
                        .opacity(0.75)
                }

                Spacer(minLength: 0)
            }

            if case .unavailable = status {
                HStack(spacing: 6) {
                    recoveryButton("Retry", action: onRetry)
                    if isMosh, let onRestart {
                        recoveryButton("Restart", action: onRestart)
                            .accessibilityLabel("Restart Mosh session")
                    }
                    Button(action: onDetails) {
                        Image(systemName: "info.circle")
                            .font(.body.weight(.medium))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Connection error details")
                }
            }
        }
        .foregroundStyle(accentColor)
        .padding(.leading, 12)
        .padding(.trailing, status.isUnavailable ? 8 : 12)
        .padding(.vertical, status.isUnavailable ? 6 : 9)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(SwiftUI.Color(appearanceSettings.currentTheme.chromeSurface).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accentColor.opacity(0.45), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private func recoveryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold).monospaced())
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background(accentColor.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(accentColor.opacity(0.45), lineWidth: 0.5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .reconnecting:
            ProgressView()
                .controlSize(.small)
                .tint(accentColor)
        case .waitingForNetwork:
            Image(systemName: "wifi.slash")
                .font(.caption.weight(.semibold))
        case .unavailable:
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption.weight(.semibold))
        case .idle:
            EmptyView()
        }
    }
}

private extension ConnectionRecoveryStatus {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

private struct TransportFallbackBanner: View {
    let presentation: ErrorPresentation
    let serverName: String
    let onAlwaysUseSSH: (() throws -> Void)?
    let onDismiss: () -> Void

    @State private var preferenceSaved = false
    @State private var saveError: ErrorPresentation?

    private let appearanceSettings = AppearanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mosh unavailable — connected using SSH")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.foreground))

                    Text(presentation.explanation)
                        .font(.caption)
                        .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.secondaryForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.secondaryForeground))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Dismiss SSH fallback notice")
            }

            if preferenceSaved {
                Label(
                    "Future connections to \(serverName) will use SSH.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentGreen))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("terminal.transport.fallback.preferenceSaved")
            } else if onAlwaysUseSSH != nil {
                HStack(spacing: 8) {
                    Button(action: saveSSHPreference) {
                        Text("Always Use SSH")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SwiftUI.Color(appearanceSettings.currentTheme.accentBlue))
                    .accessibilityLabel("Always use SSH for \(serverName)")
                    .accessibilityHint("Saves SSH for future connections to this server")
                    .accessibilityIdentifier("terminal.transport.fallback.alwaysSSH")

                    Button(action: onDismiss) {
                        Text("Not Now")
                            .font(.caption)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Keeps automatic transport selection")
                    .accessibilityIdentifier("terminal.transport.fallback.notNow")
                }
            }

            if let saveError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(saveError.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentRed))

                    Text(saveError.explanation)
                        .font(.caption)
                        .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.secondaryForeground))

                    if let recovery = saveError.recoverySuggestion {
                        Text(recovery)
                            .font(.caption)
                            .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.accentBlue))
                    }

                    DisclosureGroup("Save error details") {
                        Text(saveError.technicalDetails)
                            .font(.caption2.monospaced())
                            .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.secondaryForeground))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .tint(SwiftUI.Color(appearanceSettings.currentTheme.accentRed))
                }
                .accessibilityIdentifier("terminal.transport.fallback.saveError")
            }

            DisclosureGroup("Technical details") {
                Text(presentation.technicalDetails)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SwiftUI.Color(appearanceSettings.currentTheme.secondaryForeground))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .tint(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SwiftUI.Color(appearanceSettings.currentTheme.accentYellow).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            SwiftUI.Color(appearanceSettings.currentTheme.accentYellow).opacity(0.3),
                            lineWidth: 0.5
                        )
                )
        )
        .accessibilityIdentifier("terminal.transport.fallback")
    }

    private func saveSSHPreference() {
        guard let onAlwaysUseSSH else { return }

        do {
            try onAlwaysUseSSH()
            saveError = nil
            preferenceSaved = true
            HapticService.success()
        } catch {
            saveError = ErrorPresentation.sshTransportPreferenceSaveFailure(
                error,
                context: presentation.context
            )
            HapticService.error()
        }
    }
}
