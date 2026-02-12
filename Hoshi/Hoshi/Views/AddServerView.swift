import SwiftUI
import SwiftData

struct AddServerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var selectedKeyTag: String?
    @State private var showKeyGenerator = false
    @State private var useMosh = false
    @State private var tmuxSession = ""
    @State private var errorMessage: String?

    // When editing an existing server
    var existingServer: Server?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("Display Name", text: $name)
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
                    Toggle("Use Mosh", isOn: $useMosh)

                    if useMosh {
                        Text("Mosh provides a resilient connection that survives network changes and sleep. Requires mosh-server on the remote host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("tmux Session") {
                    TextField("Session name (optional)", text: $tmuxSession)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("When set, this connection auto-attaches to the named tmux session. Leave blank to be prompted on each connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(existingServer != nil ? "Edit Server" : "Add Server")
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
                }
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
    }

    private func save() {
        guard let portNumber = Int(port), portNumber > 0, portNumber <= 65535 else {
            errorMessage = "Port must be a number between 1 and 65535."
            return
        }

        // Store password in Keychain if using password auth
        let trimmedTmux = tmuxSession.trimmingCharacters(in: .whitespaces)
        let tmuxValue: String? = trimmedTmux.isEmpty ? nil : trimmedTmux

        if let server = existingServer {
            // Update existing server
            server.name = name
            server.hostname = hostname
            server.port = portNumber
            server.username = username
            server.authMethod = authMethod
            server.useMosh = useMosh
            server.tmuxSession = tmuxValue

            if authMethod == .password && !password.isEmpty {
                try? KeychainService.shared.storePassword(password, forServer: server.id)
            }
        } else {
            // Create new server
            let server = Server(
                name: name,
                hostname: hostname,
                port: portNumber,
                username: username,
                authMethod: authMethod,
                useMosh: useMosh,
                tmuxSession: tmuxValue
            )

            if authMethod == .password && !password.isEmpty {
                try? KeychainService.shared.storePassword(password, forServer: server.id)
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
        useMosh = server.useMosh
        tmuxSession = server.tmuxSession ?? ""

        // Retrieve stored password if available
        if let storedPassword = try? KeychainService.shared.retrievePassword(forServer: server.id) {
            password = storedPassword
        }
    }
}

#Preview {
    AddServerView()
        .modelContainer(for: Server.self, inMemory: true)
}
