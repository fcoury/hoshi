import SwiftUI

struct TmuxCommandPaletteView: View {
    let onCommand: ([UInt8]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var presentedError: ErrorPresentation?

    private let configuration = TmuxConfigurationService.shared

    private var matchingBuiltIns: [TmuxCommand] {
        matching(TmuxCommand.builtIn)
    }

    private var matchingCustomCommands: [TmuxCommand] {
        matching(configuration.customCommands)
    }

    var body: some View {
        NavigationStack {
            List {
                if !matchingCustomCommands.isEmpty {
                    Section("Your Shortcuts") {
                        ForEach(matchingCustomCommands) { command in
                            commandRow(command)
                        }
                    }
                }

                Section("tmux Commands") {
                    ForEach(matchingBuiltIns) { command in
                        commandRow(command)
                    }
                }

                if matchingBuiltIns.isEmpty && matchingCustomCommands.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("tmux Commands")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Find a command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        TmuxSettingsView()
                    } label: {
                        Label("Configure tmux", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .alert(presentedError?.title ?? "Unable to Send Shortcut", isPresented: Binding(
                get: { presentedError != nil },
                set: { if !$0 { presentedError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(presentedError?.fullMessage ?? "")
            }
        }
    }

    private func matching(_ commands: [TmuxCommand]) -> [TmuxCommand] {
        guard !searchText.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedStandardContains(searchText)
                || $0.detail.localizedStandardContains(searchText)
                || $0.sequence.localizedStandardContains(searchText)
        }
    }

    private func commandRow(_ command: TmuxCommand) -> some View {
        Button {
            do {
                let bytes = try command.bytes(prefix: configuration.prefix)
                HapticService.lightTap()
                onCommand(bytes)
                dismiss()
            } catch {
                presentedError = ErrorPresentation.classify(
                    error,
                    context: ErrorContext(operation: .tmux)
                )
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.title)
                    if !command.detail.isEmpty {
                        Text(command.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: command.systemImage)
            }
        }
        .accessibilityHint(command.sendsPrefix
            ? "Sends the tmux prefix followed by \(command.sequence)"
            : "Sends \(command.sequence) directly")
    }
}
