import SwiftUI
import UIKit

struct AgentMonitoringSettingsView: View {
    @State private var endpoint = ""
    @State private var token = ""
    @State private var presentedError: ErrorPresentation?
    @State private var showRemoveConfirmation = false

    private let events = AgentEventCenter.shared
    private let liveActivities = AgentLiveActivityService.shared
    private let appLock = AppLockService.shared
    private let configuration = AgentCompanionConfiguration.shared
    private let monitor = AgentCompanionMonitor.shared

    var body: some View {
        Form {
            notificationSection
            liveActivitySection
            companionSection
            hookSection

            if let presentedError {
                Section {
                    ErrorPresentationView(presentation: presentedError)
                }
            }
        }
        .navigationTitle("Agent Monitoring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            endpoint = configuration.endpoint?.absoluteString ?? ""
            events.refreshLiveActivities()
        }
        .confirmationDialog("Remove Companion?", isPresented: $showRemoveConfirmation) {
            Button("Remove Companion", role: .destructive, action: removeCompanion)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved endpoint and deletes its authentication token from Keychain.")
        }
    }

    private var liveActivitySection: some View {
        Section {
            Toggle("Agent Live Activities", isOn: Binding(
                get: { liveActivities.isEnabled },
                set: events.setLiveActivitiesEnabled
            ))

            LabeledContent("Status") {
                Label(liveActivityStatus.title, systemImage: liveActivityStatus.systemImage)
                    .foregroundStyle(liveActivityStatus.style)
            }

            if !liveActivities.areActivitiesAvailable {
                Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            } else if liveActivities.isEnabled && liveActivities.dismissedActivityCount > 0 {
                Button("Restart Live Activities", action: events.restartDismissedLiveActivities)
            }

            if liveActivities.isEnabled {
                Toggle("Show Server Names", isOn: Binding(
                    get: { liveActivities.showsServerNames },
                    set: events.setLiveActivityServerNamesVisible
                ))
                .disabled(appLock.isEnabled)

                if appLock.isEnabled {
                    Label("Server names stay hidden while app lock is enabled.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let presentation = liveActivities.presentedError {
                ErrorPresentationView(presentation: presentation)
            }
        } header: {
            Text("Lock Screen & Dynamic Island")
        } footer: {
            Text(liveActivityFooter)
        }
    }

    private var liveActivityFooter: String {
        let privacy = "Follow active agent sessions and attention requests without sending terminal output, event messages, or credentials to your Lock Screen. Server names are hidden by default."
        guard liveActivities.areActivitiesAvailable,
              liveActivities.isEnabled,
              liveActivities.monitoredSessionCount == 0 else {
            return privacy
        }
        return "Open an authenticated terminal session to start its Live Activity.\n\n\(privacy)"
    }

    private var liveActivityStatus: (title: String, systemImage: String, style: Color) {
        guard liveActivities.areActivitiesAvailable else {
            return ("Disabled in iOS", "exclamationmark.triangle.fill", .orange)
        }
        guard liveActivities.isEnabled else {
            return ("Off", "circle", .secondary)
        }
        if liveActivities.dismissedActivityCount > 0 && liveActivities.activeActivityCount == 0 {
            return ("Dismissed", "xmark.circle", .secondary)
        }
        guard liveActivities.activeActivityCount > 0 else {
            if liveActivities.monitoredSessionCount > 0 {
                return ("Unable to Start", "exclamationmark.circle.fill", .red)
            }
            return ("Waiting for Session", "clock", .secondary)
        }

        let count = liveActivities.activeActivityCount
        if count < liveActivities.monitoredSessionCount {
            return (
                "\(count) of \(liveActivities.monitoredSessionCount) Active",
                "exclamationmark.circle.fill",
                .orange
            )
        }
        return (count == 1 ? "1 Active" : "\(count) Active", "waveform.path.ecg", .green)
    }

    private var notificationSection: some View {
        Section {
            Toggle("Agent Notifications", isOn: Binding(
                get: { events.notificationsEnabled },
                set: { enabled in
                    Task { await events.setNotificationsEnabled(enabled) }
                }
            ))

            if let presentation = events.presentedNotificationError {
                ErrorPresentationView(presentation: presentation)
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

                if let presentation = monitor.presentedError {
                    ErrorPresentationView(presentation: presentation)
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
            presentedError = nil
            monitor.stop()
            monitor.start()
        } catch {
            presentCompanionError(error)
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
            presentedError = nil
        } catch {
            presentCompanionError(error)
        }
    }

    private func removeCompanion() {
        do {
            monitor.stop()
            try configuration.removeConfiguration()
            endpoint = ""
            token = ""
            presentedError = nil
        } catch {
            presentCompanionError(error)
        }
    }

    private func presentCompanionError(_ error: any Error) {
        let endpoint = configuration.endpoint
        presentedError = ErrorPresentation.classify(
            error,
            context: ErrorContext(
                operation: .companion,
                hostname: endpoint?.host,
                port: endpoint?.port
            )
        )
    }
}
