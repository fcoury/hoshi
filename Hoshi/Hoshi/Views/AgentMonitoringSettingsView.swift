import SwiftUI
import UIKit

struct AgentMonitoringSettingsView: View {
    @State private var endpoint = ""
    @State private var token = ""
    @State private var errorMessage: String?
    @State private var showRemoveConfirmation = false

    private let events = AgentEventCenter.shared
    private let configuration = AgentCompanionConfiguration.shared
    private let monitor = AgentCompanionMonitor.shared

    var body: some View {
        Form {
            notificationSection
            companionSection
            hookSection

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Agent Monitoring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            endpoint = configuration.endpoint?.absoluteString ?? ""
        }
        .confirmationDialog("Remove Companion?", isPresented: $showRemoveConfirmation) {
            Button("Remove Companion", role: .destructive, action: removeCompanion)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved endpoint and deletes its authentication token from Keychain.")
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle("Agent Notifications", isOn: Binding(
                get: { events.notificationsEnabled },
                set: { enabled in
                    Task { await events.setNotificationsEnabled(enabled) }
                }
            ))

            if let error = events.notificationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Local Notifications")
        } footer: {
            Text("Get an alert when an agent finishes, needs attention, or requests approval. Approval actions are never executed automatically.")
        }
    }

    private var companionSection: some View {
        Section {
            TextField("https://agents.example.com/events", text: $endpoint)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField(
                configuration.hasToken ? "New token (leave empty to keep existing)" : "Bearer token",
                text: $token
            )
            .textContentType(.password)

            Button("Save Companion", action: saveCompanion)
                .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if configuration.endpoint != nil {
                Toggle("Poll Companion", isOn: Binding(
                    get: { configuration.isEnabled },
                    set: setCompanionEnabled
                ))

                if monitor.isPolling {
                    Label("Connected", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }

                if let lastSync = monitor.lastSync {
                    LabeledContent("Last Sync") {
                        Text(lastSync, style: .relative)
                    }
                }

                if let error = monitor.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Remove Companion", role: .destructive) {
                    showRemoveConfirmation = true
                }
            }
        } header: {
            Text("Self-Hosted Companion")
        } footer: {
            Text("Optional and account-free. HTTPS is required except for localhost development. The bearer token stays in your device Keychain.")
        }
    }

    private var hookSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = "python3 scripts/hoshi-agent-companion.py emit completed --title 'Agent finished'"
                HapticService.success()
            } label: {
                Label("Copy Example Hook", systemImage: "doc.on.doc")
            }
        } header: {
            Text("Remote Hooks")
        } footer: {
            Text("Install scripts/hoshi-agent-companion.py on your server. It can emit SSH terminal events directly or post them to your self-hosted event feed.")
        }
    }

    private func saveCompanion() {
        do {
            let value: String
            if token.isEmpty, configuration.endpoint != nil {
                value = try configuration.loadToken()
            } else {
                value = token
            }
            try configuration.configure(endpoint: endpoint, token: value)
            token = ""
            errorMessage = nil
            monitor.stop()
            monitor.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setCompanionEnabled(_ enabled: Bool) {
        do {
            try configuration.setEnabled(enabled)
            if enabled {
                monitor.start()
            } else {
                monitor.stop()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeCompanion() {
        do {
            monitor.stop()
            try configuration.removeConfiguration()
            endpoint = ""
            token = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
