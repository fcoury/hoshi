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
                        Text("\(server.hostname):\(server.port)")
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
                    if server.useMosh {
                        LabeledContent("Mode") {
                            Text("MOSH")
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

                if let error = connectionVM.errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Connection Failed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.headline)
                            Text(error)
                                .font(.body)
                                .foregroundStyle(.secondary)
                            if let suggestion = recoverySuggestion(for: error) {
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
                // Pre-fill password from Keychain
                if let storedPassword = try? KeychainService.shared.retrievePassword(forServer: server.id) {
                    password = storedPassword
                }
                // Pre-select first key if using key auth
                if server.authMethod == .key {
                    selectedKeyTag = SSHKeyService.shared.listKeys().first
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

    // Map error messages back to recovery suggestions
    private func recoverySuggestion(for errorMessage: String) -> String? {
        if errorMessage.contains("refused") {
            return "Verify the server is running and the port is correct. Check firewall rules."
        } else if errorMessage.contains("Authentication") || errorMessage.contains("auth") {
            return "Check your credentials and try again."
        } else if errorMessage.contains("timed out") {
            return "Check your network connection and verify the server is reachable."
        } else if errorMessage.contains("unreachable") {
            return "Check your WiFi or cellular connection."
        } else if errorMessage.contains("mosh-server") {
            return "Install mosh-server on the remote host or disable Mosh in server settings."
        } else if errorMessage.contains("UDP") {
            return "Check that UDP ports 60000-61000 are open on the server firewall."
        }
        return "Try reconnecting. If the problem persists, check server logs."
    }
}
