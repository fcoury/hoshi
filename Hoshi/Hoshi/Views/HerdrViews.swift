import SwiftUI

struct HerdrSessionRow: View {
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

struct HerdrAgentRow: View {
    let agent: HerdrAgent
    /// Marks the agent this terminal is showing.
    var isCurrent = false

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
            if isCurrent {
                Image(systemName: "eye.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Showing in this terminal")
            }
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

/// In-session overview of Herdr agents on the connected host. Tapping an agent
/// focuses it in place when this terminal shows that Herdr session; otherwise
/// it opens in a new Hoshi session so the current terminal is left alone.
struct HerdrAgentsView: View {
    let connectionVM: ConnectionViewModel
    var onOpenInNewSession: ((HerdrAttachment) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var actionError: String?

    private var herdr: HerdrInventory? { connectionVM.detectedHerdr }
    private var attachment: HerdrAttachment? { connectionVM.herdrAttachment }

    private var attentionAgents: [(session: String, agent: HerdrAgent)] {
        (herdr?.runningSessions ?? []).flatMap { session in
            session.agents.filter { $0.status == .blocked }.map { (session.name, $0) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let herdr, !herdr.runningSessions.isEmpty {
                    agentList(herdr)
                } else {
                    ContentUnavailableView(
                        "No Herdr Agents",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text(herdr == nil
                            ? "Herdr was not found on this server."
                            : "No Herdr session is running on this server.")
                    )
                }
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh agents")
                    }
                }
            }
            .alert(
                "Herdr",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
        .task { await refresh() }
    }

    private func agentList(_ herdr: HerdrInventory) -> some View {
        List {
            if let attachment {
                Section {
                    Label(currentDescription(attachment), systemImage: "eye")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !attentionAgents.isEmpty {
                Section("Needs Input") {
                    ForEach(attentionAgents, id: \.agent.id) { item in
                        agentButton(item.agent, session: item.session)
                    }
                }
            }

            ForEach(herdr.runningSessions) { session in
                ForEach(session.agentsByWorkspace) { group in
                    Section {
                        ForEach(group.agents) { agent in
                            agentButton(agent, session: session.name)
                        }
                    } header: {
                        Text(herdr.runningSessions.count > 1
                            ? "\(session.name) · \(group.workspace.label)"
                            : group.workspace.label)
                    }
                }
            }

            if case .session = attachment {
                Section {
                } footer: {
                    Text("Herdr shares focus between clients, so a desktop attached to the same session switches too.")
                }
            }
        }
        .refreshable { await connectionVM.refreshHerdr() }
    }

    private func agentButton(_ agent: HerdrAgent, session: String) -> some View {
        Button {
            Task { await select(agent, session: session) }
        } label: {
            HerdrAgentRow(agent: agent, isCurrent: isCurrent(agent, session: session))
        }
        .tint(.primary)
        .disabled(isWorking || !HerdrCommand.isValidIdentifier(agent.paneID))
        .accessibilityHint(canFocusInPlace(session: session)
            ? "Shows this agent in the current terminal"
            : "Opens this agent in a new Hoshi session")
        .contextMenu {
            if canFocusInPlace(session: session) {
                Button {
                    Task { await select(agent, session: session) }
                } label: {
                    Label("Show Here", systemImage: "eye")
                }
            }
            if let onOpenInNewSession {
                Button {
                    onOpenInNewSession(.agent(session: session, paneID: agent.paneID))
                    dismiss()
                } label: {
                    Label("Open Agent in New Session", systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    onOpenInNewSession(.session(session))
                    dismiss()
                } label: {
                    Label("Open Herdr \(session) in New Session", systemImage: "square.stack.3d.up")
                }
            }
        }
    }

    private func canFocusInPlace(session: String) -> Bool {
        attachment == .session(session)
    }

    private func isCurrent(_ agent: HerdrAgent, session: String) -> Bool {
        switch attachment {
        case .session(let name): name == session && agent.focused
        case .agent(let name, let paneID): name == session && paneID == agent.paneID
        case nil: false
        }
    }

    private func currentDescription(_ attachment: HerdrAttachment) -> String {
        switch attachment {
        case .session(let name):
            return "Showing Herdr session \(name)"
        case .agent(let session, let paneID):
            let agent = herdr?.session(named: session)?.agent(paneID: paneID)
            return "Attached to \(agent?.displayName ?? paneID) in \(session)"
        }
    }

    private func select(_ agent: HerdrAgent, session: String) async {
        if canFocusInPlace(session: session) {
            isWorking = true
            defer { isWorking = false }
            do {
                try await connectionVM.focusHerdrAgent(agent, in: session)
                dismiss()
            } catch {
                actionError = error.localizedDescription
            }
        } else if let onOpenInNewSession {
            onOpenInNewSession(.agent(session: session, paneID: agent.paneID))
            dismiss()
        }
    }

    private func refresh() async {
        isWorking = true
        await connectionVM.refreshHerdr()
        isWorking = false
    }
}
