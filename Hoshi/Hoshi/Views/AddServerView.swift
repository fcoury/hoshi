import SwiftUI
import SwiftData

struct AddServerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var isFavorite = false
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var selectedKeyTag: String?
    @State private var showKeyGenerator = false
    @State private var transportPolicy: ConnectionTransportPolicy = .auto
    @State private var tmuxPolicy: TmuxConnectionPolicy = .alwaysAsk
    @State private var tmuxSession = ""
    @State private var moshServerPath = ""
    @State private var moshUDPPortRange = ""
    @State private var presentedError: ErrorPresentation?
    @FocusState private var isNameFocused: Bool

    // When editing an existing server
    var existingServer: Server?
    var duplicatedServer: Server?
    var suggestedName: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("Display Name", text: $name)
                        .focused($isNameFocused)
                        .textContentType(.nickname)
                    TextField("Hostname or IP", text: $hostname)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Favorite", isOn: $isFavorite)
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("Password").tag(AuthMethod.password)
                        Text("SSH Key").tag(AuthMethod.key)
                    }

                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } else {
                        keySelector
                    }
                }

                Section("Connection Mode") {
                    Picker("Transport", selection: $transportPolicy) {
                        ForEach(ConnectionTransportPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }

                    if transportPolicy != .ssh {
                        TextField("mosh-server path (optional)", text: $moshServerPath)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        TextField("UDP range, e.g. 60000:61000", text: $moshUDPPortRange)
                            .keyboardType(.numbersAndPunctuation)

                        Text(transportPolicy == .auto
                             ? "Prefer Mosh and fall back to SSH when the remote host cannot use it."
                             : "Require Mosh, which survives network changes and sleep.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("tmux Session") {
                    Picker("Behavior", selection: $tmuxPolicy) {
                        ForEach(TmuxConnectionPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }

                    if tmuxPolicy != .rawShell {
                        TextField("Session name (optional)", text: $tmuxSession)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text(tmuxPolicy == .autoAttachLast
                             ? "Attach to this session automatically when it is available."
                             : "Show available tmux sessions whenever you connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let presentedError {
                    Section {
                        ErrorPresentationView(presentation: presentedError)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showKeyGenerator) {
                KeyGeneratorView { tag in
                    selectedKeyTag = tag
                }
            }
            .onAppear {
                if let server = existingServer {
                    populateFromServer(server)
                } else if let server = duplicatedServer {
                    populateFromServer(server)
                    name = suggestedName ?? "\(server.name) Copy"
                    isFavorite = false
                }
                isNameFocused = true
            }
        }
    }

    private var keySelector: some View {
        Group {
            let keyTags = SSHKeyService.shared.listKeys()

            if keyTags.isEmpty {
                Button("Generate SSH Key") {
                    showKeyGenerator = true
                }
            } else {
                Picker("SSH Key", selection: $selectedKeyTag) {
                    Text("Select a key").tag(nil as String?)
                    ForEach(keyTags, id: \.self) { tag in
                        Text(tag).tag(tag as String?)
                    }
                }

                Button("Generate New Key") {
                    showKeyGenerator = true
                }
                .font(.caption)
            }
        }
    }

    private var isValid: Bool {
        !name.isEmpty && !hostname.isEmpty && !username.isEmpty && !port.isEmpty
            && (authMethod != .key || selectedKeyTag != nil)
    }

    private func save() {
        presentedError = nil
        guard let portNumber = Int(port), portNumber > 0, portNumber <= 65535 else {
            presentError(ErrorMessageFailure(message: "Port must be a number between 1 and 65535."))
            return
        }

        let trimmedMoshPortRange = moshUDPPortRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if transportPolicy != .ssh,
           !trimmedMoshPortRange.isEmpty,
           MoshPortRange(trimmedMoshPortRange) == nil {
            presentError(ConnectionCoordinatorError.invalidMoshPortRange(trimmedMoshPortRange))
            return
        }

        // Store password in Keychain if using password auth
        let trimmedTmux = tmuxSession.trimmingCharacters(in: .whitespaces)
        let tmuxValue: String? = trimmedTmux.isEmpty ? nil : trimmedTmux
        let trimmedMoshServerPath = moshServerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredMoshServerPath: String? = trimmedMoshServerPath.isEmpty ? nil : trimmedMoshServerPath
        let configuredMoshPortRange: String? = trimmedMoshPortRange.isEmpty ? nil : trimmedMoshPortRange
        let selectedKeyID = authMethod == .key ? selectedKeyTag : nil

        if let server = existingServer {
            do {
                try updateCredentials(forServer: server.id)
            } catch {
                presentError(error)
                return
            }

            // Update existing server
            server.name = name
            server.hostname = hostname
            server.port = portNumber
            server.username = username
            server.authMethod = authMethod
            server.keyID = selectedKeyID
            server.isFavorite = isFavorite
            server.transportPolicy = transportPolicy
            server.tmuxPolicy = tmuxPolicy
            server.tmuxSession = tmuxValue
            server.moshServerPath = configuredMoshServerPath
            server.moshUDPPortRange = configuredMoshPortRange
        } else {
            // Create new server
            let server = Server(
                name: name,
                hostname: hostname,
                port: portNumber,
                username: username,
                authMethod: authMethod,
                keyID: selectedKeyID,
                useMosh: transportPolicy != .ssh,
                isFavorite: isFavorite,
                tmuxSession: tmuxValue,
                transportPolicy: transportPolicy,
                tmuxPolicy: tmuxPolicy,
                moshServerPath: configuredMoshServerPath,
                moshUDPPortRange: configuredMoshPortRange
            )

            do {
                try updateCredentials(forServer: server.id)
            } catch {
                presentError(error)
                return
            }

            modelContext.insert(server)
        }

        dismiss()
    }

    private func populateFromServer(_ server: Server) {
        name = server.name
        hostname = server.hostname
        port = String(server.port)
        username = server.username
        authMethod = server.authMethod
        isFavorite = server.isFavorite
        selectedKeyTag = server.keyID
        transportPolicy = server.transportPolicy
        tmuxPolicy = server.tmuxPolicy
        tmuxSession = server.tmuxSession ?? ""
        moshServerPath = server.moshServerPath ?? ""
        moshUDPPortRange = server.moshUDPPortRange ?? ""

        // Retrieve stored password if available
        if server.authMethod == .password {
            do {
                password = try KeychainService.shared.retrievePassword(forServer: server.id) ?? ""
            } catch {
                presentError(error)
            }
        }
    }

    private func presentError(_ error: any Error) {
        presentedError = ErrorPresentation.classify(
            error,
            context: ErrorContext(
                operation: .credentials,
                hostname: hostname,
                port: Int(port),
                username: username,
                authenticationMethod: authMethod.rawValue
            )
        )
    }

    private func updateCredentials(forServer serverID: UUID) throws {
        switch authMethod {
        case .password:
            if password.isEmpty {
                try KeychainService.shared.deletePassword(forServer: serverID)
            } else {
                try KeychainService.shared.storePassword(password, forServer: serverID)
            }
        case .key:
            guard let selectedKeyTag,
                  try KeychainService.shared.retrievePrivateKey(withTag: selectedKeyTag) != nil else {
                throw SSHConnectionError.keyNotFound
            }
            try KeychainService.shared.deletePassword(forServer: serverID)
        }
    }

    private var navigationTitle: String {
        if existingServer != nil { return "Edit Server" }
        if duplicatedServer != nil { return "Duplicate Server" }
        return "Add Server"
    }
}

#Preview {
    AddServerView()
        .modelContainer(for: Server.self, inMemory: true)
}
