import SwiftUI

// Shows detected tmux and Herdr sessions and lets the user attach, create new, or skip
struct TmuxSessionPickerView: View {
    let sessions: [TmuxSessionInfo]
    var tmuxAvailable = true
    var herdr: HerdrInventory?
    var onRefresh: (() -> Void)?
    let onChoice: (TmuxChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showCreateSession = false
    @State private var newSessionName = ""
    @State private var showCreateHerdrSession = false
    @State private var newHerdrSessionName = HerdrDiscovery.suggestedSessionName

    private func matches(_ text: String?) -> Bool {
        guard !searchText.isEmpty else { return true }
        return text?.localizedStandardContains(searchText) ?? false
    }

    private var filteredHerdrSessions: [HerdrSessionInfo] {
        (herdr?.sessions ?? []).compactMap { session in
            if matches(session.name) { return session }
            let agents = session.agents.filter {
                matches($0.agent) || matches($0.title) || matches($0.directoryName)
            }
            guard !agents.isEmpty else { return nil }
            return HerdrSessionInfo(name: session.name, isRunning: session.isRunning, agents: agents)
        }
    }

    private var hasHerdrSession: Bool {
        herdr?.sessions.contains(where: { $0.name == HerdrDiscovery.suggestedSessionName }) ?? false
    }

    private var filteredSessions: [TmuxSessionInfo] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Raw-shell access is an explicit action, distinct from cancelling the connection.
                Section {
                    Button {
                        onChoice(.skip)
                        dismiss()
                    } label: {
                        Label("Open Raw Shell", systemImage: "terminal")
                    }
                }

                if herdr != nil {
                    herdrSections
                }

                // Sessions list with "New Session" as first item
                if tmuxAvailable {
                    Section("tmux Sessions") {
                        Button {
                            newSessionName = ""
                            showCreateSession = true
                        } label: {
                            Label("New Session", systemImage: "plus.rectangle")
                        }

                        if filteredSessions.isEmpty {
                            Label("No sessions found", systemImage: "text.rectangle.page")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredSessions) { session in
                                Button {
                                    onChoice(.attach(session))
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(session.name)
                                                .font(.headline)
                                            HStack(spacing: 6) {
                                                Text("\(session.windows) window\(session.windows == 1 ? "" : "s")")
                                                if let activity = session.lastActivity {
                                                    Text("·")
                                                    Text(activity, style: .relative)
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        if session.isAttached {
                                            Text("attached")
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundStyle(.green)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.15))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                }
                                .tint(.primary)
                                .accessibilityElement(children: .combine)
                                .accessibilityHint("Attaches to this tmux session")
                            }
                        }
                    }
                }
            }
            .navigationTitle(herdr == nil ? "tmux" : "Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: herdr == nil ? "Find tmux sessions" : "Find sessions or agents")
            .alert("New tmux Session", isPresented: $showCreateSession) {
                TextField("Session name (optional)", text: $newSessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onChoice(name.isEmpty ? .newSession : .newNamedSession(name))
                    dismiss()
                }
                .disabled(!newSessionName.isEmpty && !TmuxDetectionService.isValidSessionName(newSessionName))
            } message: {
                Text("Leave the name empty to let tmux choose one. Names cannot contain a colon or period.")
            }
            .alert("Herdr Session", isPresented: $showCreateHerdrSession) {
                TextField("Session name", text: $newHerdrSessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Open") {
                    onChoice(.herdrSession(newHerdrSessionName))
                    dismiss()
                }
                .disabled(!HerdrCommand.isValidSessionName(newHerdrSessionName))
            } message: {
                Text("Opens the session, creating it first if needed. Use letters, numbers, period, underscore or hyphen.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let onRefresh {
                        Button {
                            onRefresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh sessions")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onChoice(.cancel)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var herdrSections: some View {
        Section {
            Button {
                newHerdrSessionName = HerdrDiscovery.suggestedSessionName
                showCreateHerdrSession = true
            } label: {
                Label(
                    hasHerdrSession ? "Open Herdr Session…" : "Start Herdr Session…",
                    systemImage: "plus.rectangle.on.rectangle"
                )
            }

            ForEach(filteredHerdrSessions) { session in
                Button {
                    onChoice(.herdrSession(session.name))
                    dismiss()
                } label: {
                    HerdrSessionRow(session: session)
                }
                .tint(.primary)
                .disabled(!HerdrCommand.isValidSessionName(session.name))
                .accessibilityHint("Opens this Herdr session")
            }
        } header: {
            Text("Herdr")
        } footer: {
            if let version = herdr?.version {
                Text(version)
            }
        }

        ForEach(filteredHerdrSessions.filter { $0.isRunning && !$0.agents.isEmpty }) { session in
            Section("Agents · \(session.name)") {
                ForEach(session.agents) { agent in
                    Button {
                        onChoice(.herdrAgent(session: session.name, paneID: agent.paneID))
                        dismiss()
                    } label: {
                        HerdrAgentRow(agent: agent)
                    }
                    .tint(.primary)
                    .disabled(!HerdrCommand.isValidIdentifier(agent.paneID))
                    .accessibilityHint("Attaches directly to this agent's terminal")
                }
            }
        }
    }
}

private struct HerdrSessionRow: View {
    let session: HerdrSessionInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.attentionCount > 0 {
                Text("\(session.attentionCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .accessibilityLabel("\(session.attentionCount) need attention")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        guard session.isRunning else { return "Stopped" }
        let count = session.agents.count
        return count == 0 ? "Running" : "\(count) agent\(count == 1 ? "" : "s")"
    }
}

private struct HerdrAgentRow: View {
    let agent: HerdrAgent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.status.systemImage)
                .foregroundStyle(statusColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.headline)
                    if let directory = agent.directoryName {
                        Text(directory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(agent.title ?? agent.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(agent.status.label)
    }

    private var statusColor: Color {
        switch agent.status {
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }
}
