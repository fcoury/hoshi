import SwiftUI

struct KeyGeneratorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var keyType: SSHKeyType = .ed25519
    @State private var keyTag = ""
    @State private var generatedKey: SSHKeyPair?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var copied = false

    let onKeyGenerated: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Configuration") {
                    Picker("Key Type", selection: $keyType) {
                        ForEach(SSHKeyType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }

                    TextField("Key Name", text: $keyTag)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if keyType == .ed25519 {
                        Text("Ed25519 keys are modern, fast, and widely supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("RSA 4096-bit keys for maximum compatibility with older servers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if let key = generatedKey {
                    Section("Public Key") {
                        Text("Add this to ~/.ssh/authorized_keys on your server:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(key.publicKeyAuthorized)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)

                        Button {
                            UIPasteboard.general.string = key.publicKeyAuthorized
                            copied = true
                            // Reset after 2 seconds
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(
                                copied ? "Copied!" : "Copy to Clipboard",
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                        }
                    }

                    Section {
                        Button("Done") {
                            onKeyGenerated(key.tag)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Section {
                        Button {
                            generateKey()
                        } label: {
                            if isGenerating {
                                HStack {
                                    ProgressView()
                                    Text("Generating...")
                                        .padding(.leading, 8)
                                }
                            } else {
                                Text("Generate Key")
                            }
                        }
                        .disabled(keyTag.isEmpty || isGenerating)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Generate SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func generateKey() {
        guard !keyTag.isEmpty else { return }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let keyPair = try SSHKeyService.shared.generateKeyPair(type: keyType, tag: keyTag)
                generatedKey = keyPair
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}

#Preview {
    KeyGeneratorView { _ in }
}
