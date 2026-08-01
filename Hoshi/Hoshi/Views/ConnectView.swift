import SwiftUI

// Sheet shown when user taps a server to connect
struct ConnectView: View {
    let server: Server
    @Bindable var connectionVM: ConnectionViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case credentials
    }

    @State private var password = ""
    @State private var selectedKeyTag: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Name") {
                        Text(server.name)
                            .font(.system(size: 14, design: .monospaced))
                    }
                    LabeledContent("Host") {
                        Text(verbatim: server.endpoint)
                            .font(.system(size: 14, design: .monospaced))
                    }
                    LabeledContent("User") {
                        Text(server.username)
                            .font(.system(size: 14, design: .monospaced))
                    }
                    LabeledContent("Auth") {
                        Text(server.authMethod == .password ? "Password" : "SSH Key")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    if server.transportPolicy != .ssh {
                        LabeledContent("Mode") {
                            Text(server.transportPolicy.displayName.uppercased())
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }

                if server.authMethod == .password {
                    Section("Credentials") {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .credentials)
                    }
                } else {
                    Section("SSH Key") {
                        let keyTags = SSHKeyService.shared.listKeys()
                        if keyTags.isEmpty {
                            Text("No SSH keys found. Generate one in server settings.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Key", selection: $selectedKeyTag) {
                                Text("Select a key").tag(nil as String?)
                                ForEach(keyTags, id: \.self) { tag in
                                    Text(tag).tag(tag as String?)
                                }
                            }
                        }
                    }
                }

                // Connection progress with phase text
                if connectionVM.isConnecting {
                    Section {
                        HStack {
                            ProgressView()
                            Text(connectionVM.connectionPhase.isEmpty
                                 ? "Connecting..."
                                 : connectionVM.connectionPhase)
                                .padding(.leading, 8)
                        }
                    }
                }

                if let presentation = connectionVM.presentedError {
                    Section {
                        ErrorPresentationView(presentation: presentation)
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        connectionVM.cancelConnection()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        Task {
                            await connectionVM.connect(
                                server: server,
                                password: server.authMethod == .password ? password : nil,
                                keyTag: server.authMethod == .key ? selectedKeyTag : nil
                            )
                            if connectionVM.connectionState == .connected {
                                dismiss()
                            }
                        }
                    }
                    .disabled(connectionVM.isConnecting || !isReady)
                }
            }
            // Mosh-server installation offer
            .alert("Mosh Server Not Found", isPresented: $connectionVM.showMoshInstallOffer) {
                Button("Install") {
                    Task { await connectionVM.installMoshServer() }
                }
                Button("Use SSH Instead", role: .cancel) {
                    Task { await connectionVM.declineMoshInstall() }
                }
            } message: {
                if let pm = connectionVM.detectedPackageManager {
                    Text("mosh-server was not found on this host. Install it using \(pm.rawValue)?")
                } else {
                    Text("mosh-server was not found on this host. Would you like to install it?")
                }
            }
            .onAppear {
                switch server.authMethod {
                case .password:
                    do {
                        password = try KeychainService.shared.retrievePassword(forServer: server.id) ?? ""
                    } catch {
                        connectionVM.presentConnectionError(error, server: server, operation: .credentials)
                    }
                case .key:
                    if let selectedKeyID = server.keyID,
                       SSHKeyService.shared.listKeys().contains(selectedKeyID) {
                        selectedKeyTag = selectedKeyID
                    }
                }

                if shouldAutofocusCredentials {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        focusedField = .credentials
                    }
                }
            }
            // Auto-dismiss when connected (e.g. after install)
            .onChange(of: connectionVM.connectionState) { _, newState in
                if newState == .connected {
                    dismiss()
                }
            }
            // Dismiss when tmux picker should appear
            .onChange(of: connectionVM.showTmuxPicker) { _, show in
                if show {
                    dismiss()
                }
            }
            .hostKeyTrustPrompt()
        }
    }

    private var isReady: Bool {
        switch server.authMethod {
        case .password:
            return !password.isEmpty
        case .key:
            return selectedKeyTag != nil
        }
    }

    private var shouldAutofocusCredentials: Bool {
        guard server.authMethod == .password else { return false }
        return !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !server.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

private struct HostKeyTrustPromptModifier: ViewModifier {
    let isEnabled: Bool

    @State private var coordinator = HostKeyTrustCoordinator.shared

    func body(content: Content) -> some View {
        content.alert(
            "Trust SSH Host?",
            isPresented: Binding(
                get: { isEnabled && coordinator.pendingIdentity != nil },
                set: { presented in
                    if !presented, isEnabled, coordinator.pendingIdentity != nil {
                        coordinator.resolvePendingIdentity(trusted: false)
                    }
                }
            ),
            presenting: coordinator.pendingIdentity
        ) { _ in
            Button("Trust") {
                coordinator.resolvePendingIdentity(trusted: true)
            }
            Button("Cancel", role: .cancel) {
                coordinator.resolvePendingIdentity(trusted: false)
            }
        } message: { identity in
            Text(
                "The authenticity of \(identity.endpoint) cannot be verified.\n\n"
                    + "\(identity.algorithm) fingerprint:\n\(identity.fingerprint)\n\n"
                    + "Only continue if you recognize this fingerprint."
            )
        }
    }
}

extension View {
    func hostKeyTrustPrompt(enabled: Bool = true) -> some View {
        modifier(HostKeyTrustPromptModifier(isEnabled: enabled))
    }
}
