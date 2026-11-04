import SwiftUI

struct HerdrSessionRow: View {
    let session: HerdrSessionInfo

    var body: some View {
        HStack {
            if session.machine != nil {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
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
        if let machine = session.machine {
            guard session.isRunning else { return "Unreachable from this server" }
            let count = session.agents.count
            return "\(machine.target) · \(count) agent\(count == 1 ? "" : "s")"
        }
        guard session.isRunning else { return "Stopped" }
        let count = session.agents.count
        return count == 0 ? "Running" : "\(count) agent\(count == 1 ? "" : "s")"
    }
}

struct HerdrAgentRow: View {
    let agent: HerdrAgent
    /// Marks the agent this terminal is showing.
    var isCurrent = false
    /// The saved machine the agent runs on, when not on this server.
    var machine: String? = nil

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
                    if let machine {
                        Label(machine, systemImage: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

    private var statusColor: Color { agent.status.tint }
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
    @State private var replyTarget: HerdrAgentTarget?

    private var herdr: HerdrInventory? { connectionVM.detectedHerdr }
    private var attachment: HerdrAttachment? { connectionVM.herdrAttachment }

    private var attentionAgents: [(session: HerdrSessionInfo, agent: HerdrAgent)] {
        (herdr?.runningSessions ?? []).flatMap { session in
            session.agents.filter { $0.status == .blocked }.map { (session, $0) }
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
            .navigationDestination(item: $replyTarget) { target in
                HerdrReplyView(
                    connectionVM: connectionVM,
                    target: target,
                    onOpenInNewSession: onOpenInNewSession,
                    isEmbedded: true
                )
            }
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
                        Button {
                            replyTarget = item.session.target(for: item.agent)
                        } label: {
                            HStack {
                                HerdrAgentRow(agent: item.agent, machine: item.session.machine?.label)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                        .accessibilityHint("Opens a reply card for this agent")
                    }
                }
            }

            ForEach(herdr.runningSessions) { session in
                ForEach(session.agentsByWorkspace) { group in
                    Section {
                        ForEach(group.agents) { agent in
                            agentButton(agent, in: session)
                        }
                    } header: {
                        sectionHeader(session: session, workspace: group.workspace, herdr: herdr)
                    }
                }
            }

            unreachableMachines(herdr)

            if attachment.map({ if case .agent = $0 { false } else { true } }) == true {
                Section {
                } footer: {
                    Text("Herdr shares focus between clients, so a desktop attached to the same session switches too.")
                }
            }
        }
        .refreshable { await connectionVM.refreshHerdr() }
    }

    @ViewBuilder
    private func sectionHeader(session: HerdrSessionInfo, workspace: HerdrWorkspace, herdr: HerdrInventory) -> some View {
        if let machine = session.machine {
            Label("\(machine.label) · \(workspace.label)", systemImage: "server.rack")
        } else if herdr.runningSessions.count > 1 {
            Text("\(session.name) · \(workspace.label)")
        } else {
            Text(workspace.label)
        }
    }

    @ViewBuilder
    private func unreachableMachines(_ herdr: HerdrInventory) -> some View {
        let offline = herdr.machineSessions.filter { !$0.isRunning }
        if !offline.isEmpty {
            Section {
                ForEach(offline) { session in
                    Label(session.displayName, systemImage: "server.rack")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Unreachable Machines")
            } footer: {
                Text("Herdr on this server could not reach these machines. Run `herdr machine status` there for details.")
            }
        }
    }

    private func agentButton(_ agent: HerdrAgent, in session: HerdrSessionInfo) -> some View {
        let target = session.target(for: agent)
        let inPlace = connectionVM.canFocusHerdrInPlace(target)
        return Button {
            Task { await select(agent, in: session) }
        } label: {
            HerdrAgentRow(agent: agent, isCurrent: isCurrent(agent, in: session))
        }
        .tint(.primary)
        .disabled(isWorking || !HerdrCommand.isValidIdentifier(agent.paneID))
        .accessibilityHint(inPlace
            ? "Shows this agent in the current terminal"
            : "Opens this agent in a new Hoshi session")
        .contextMenu {
            Button {
                replyTarget = target
            } label: {
                Label("Reply…", systemImage: "text.bubble")
            }
            if inPlace {
                Button {
                    Task { await select(agent, in: session) }
                } label: {
                    Label("Show Here", systemImage: "eye")
                }
            }
            if let onOpenInNewSession {
                Button {
                    onOpenInNewSession(Self.newSessionAttachment(for: agent, in: session))
                    dismiss()
                } label: {
                    Label(
                        session.machine == nil ? "Open Agent in New Session" : "Open on \(session.displayName) in New Session",
                        systemImage: "plus.rectangle.on.rectangle"
                    )
                }
                if session.machine == nil {
                    Button {
                        onOpenInNewSession(.session(session.name))
                        dismiss()
                    } label: {
                        Label("Open Herdr \(session.name) in New Session", systemImage: "square.stack.3d.up")
                    }
                }
            }
        }
    }

    /// Local agents attach directly; agents on a saved machine open that
    /// machine's Herdr UI focused on the agent, because Herdr does not
    /// forward interactive attachment.
    static func newSessionAttachment(for agent: HerdrAgent, in session: HerdrSessionInfo) -> HerdrAttachment {
        if let machine = session.machine {
            return .machine(id: machine.id, paneID: agent.paneID)
        }
        return .agent(session: session.name, paneID: agent.paneID)
    }

    private func isCurrent(_ agent: HerdrAgent, in session: HerdrSessionInfo) -> Bool {
        switch attachment {
        case .agent(let name, let paneID): session.machine == nil && name == session.name && paneID == agent.paneID
        case .some(let attachment): attachment.shows(session) && agent.focused
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
        case .machine(let id, _):
            return "Showing Herdr on \(herdr?.machine(id: id)?.label ?? "a saved machine")"
        }
    }

    private func select(_ agent: HerdrAgent, in session: HerdrSessionInfo) async {
        let target = session.target(for: agent)
        if connectionVM.canFocusHerdrInPlace(target) {
            isWorking = true
            defer { isWorking = false }
            do {
                try await connectionVM.focusHerdrAgent(target)
                dismiss()
            } catch {
                actionError = error.localizedDescription
            }
        } else if let onOpenInNewSession {
            onOpenInNewSession(Self.newSessionAttachment(for: agent, in: session))
            dismiss()
        }
    }

    private func refresh() async {
        isWorking = true
        await connectionVM.refreshHerdr()
        isWorking = false
    }
}
