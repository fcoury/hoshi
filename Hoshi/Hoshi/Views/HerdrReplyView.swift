import SwiftUI

/// Reply card for one Herdr agent: recent output, the choices of an approval
/// or question prompt, and a text field. Every action is an explicit tap;
/// Hoshi never answers a prompt on its own.
struct HerdrReplyView: View {
    let connectionVM: ConnectionViewModel
    let target: HerdrAgentTarget
    var onOpenInNewSession: ((HerdrAttachment) -> Void)?
    /// Pushed inside another navigation stack, such as the agents sheet.
    var isEmbedded = false
    @Environment(\.dismiss) private var dismiss

    @State private var output = ""
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var replyText = ""
    @State private var isSending = false
    @FocusState private var replyFocused: Bool

    private var agent: HerdrAgent? { connectionVM.herdrAgent(for: target) }
    private var status: HerdrAgentStatus { agent?.status ?? .unknown }
    private var options: [HerdrPromptOption] {
        status == .blocked ? HerdrPromptOption.parse(output) : []
    }
    private var canShowHere: Bool { connectionVM.herdrAttachment == .session(target.session) }

    var body: some View {
        if isEmbedded {
            content
        } else {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            outputView
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .navigationTitle(agent?.displayName ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .alert(
            "Reply Failed",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task(id: target) { await pollOutput() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            HerdrStatusBadge(status: status)
            VStack(alignment: .leading, spacing: 2) {
                if let title = agent?.title {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Text([agent?.directoryName, "Herdr \(target.session)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let loadError, output.isEmpty {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if !hasLoaded {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(output.isEmpty ? "No recent output." : output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                Color.clear.frame(height: 1).id("bottom")
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 12)
            .onChange(of: output) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(options) { option in
                        Button {
                            perform { try await connectionVM.sendHerdrKeys(optionKeys(option), to: target) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(option.number)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .frame(width: 22, height: 22)
                                    .background(.tint.opacity(option.isSelected ? 0.25 : 0.12), in: .circle)
                                Text(option.label)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                            .overlay {
                                if option.isSelected {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.5))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Option \(option.number): \(option.label)")
                    }
                }
            }

            HStack(spacing: 8) {
                if status == .blocked {
                    keyButton("Enter", systemImage: "return", keys: [.enter])
                    keyButton("Esc", systemImage: "escape", keys: [.escape])
                    keyButton("Up", systemImage: "arrow.up", keys: [.up], iconOnly: true)
                    keyButton("Down", systemImage: "arrow.down", keys: [.down], iconOnly: true)
                } else if status == .working {
                    keyButton("Interrupt", systemImage: "stop.fill", keys: [.escape])
                }
                Spacer(minLength: 0)
                if isSending { ProgressView() }
            }

            HStack(spacing: 8) {
                TextField(replyPlaceholder, text: $replyText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($replyFocused)
                    .submitLabel(.send)
                    .onSubmit(sendText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 18))
                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .accessibilityLabel("Send reply")
            }
        }
        .disabled(isSending)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var moreMenu: some View {
        Menu {
            if canShowHere {
                Button {
                    Task {
                        if let agent { try? await connectionVM.focusHerdrAgent(agent, in: target.session) }
                        dismiss()
                    }
                } label: {
                    Label("Show in Terminal", systemImage: "eye")
                }
            }
            if let onOpenInNewSession {
                Button {
                    onOpenInNewSession(.agent(session: target.session, paneID: target.paneID))
                    dismiss()
                } label: {
                    Label("Open in New Session", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    private var replyPlaceholder: String {
        switch status {
        case .blocked: "Answer \(agent?.displayName ?? "agent")…"
        default: "Message \(agent?.displayName ?? "agent")…"
        }
    }

    private func keyButton(
        _ title: String,
        systemImage: String,
        keys: [HerdrKey],
        iconOnly: Bool = false
    ) -> some View {
        Button {
            perform { try await connectionVM.sendHerdrKeys(keys, to: target) }
        } label: {
            if iconOnly {
                Image(systemName: systemImage).frame(width: 20)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(title)
    }

    // MARK: - Actions

    /// Digits select a menu entry directly in Claude Code and Codex.
    private func optionKeys(_ option: HerdrPromptOption) -> [HerdrKey] {
        HerdrKey.key(for: Character(String(option.number))).map { [$0] } ?? [.enter]
    }

    private func sendText() {
        let text = replyText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform {
            try await connectionVM.submitHerdrText(text, to: target)
            replyText = ""
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isSending else { return }
        isSending = true
        Task {
            do {
                try await action()
                HapticService.success()
            } catch {
                HapticService.error()
                actionError = error.localizedDescription
            }
            isSending = false
            // Give the agent a moment to redraw before showing the result.
            try? await Task.sleep(for: .milliseconds(400))
            await load()
        }
    }

    private func load() async {
        do {
            let text = try await connectionVM.readHerdrAgent(target)
            output = Self.trimmed(text)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    private func pollOutput() async {
        while !Task.isCancelled {
            if !isSending { await load() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Drops trailing blank lines so the newest output sits at the bottom.
    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

/// A tinted status capsule shared by Herdr views.
struct HerdrStatusBadge: View {
    let status: HerdrAgentStatus

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.15), in: .capsule)
    }
}

extension HerdrAgentStatus {
    var tint: Color {
        switch self {
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }
}
