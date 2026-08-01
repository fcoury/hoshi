import SwiftUI

struct TmuxSettingsView: View {
    @State private var editingCommand: TmuxCommand?
    @State private var customPrefix = ""
    @State private var presentedError: ErrorPresentation?

    private let configuration = TmuxConfigurationService.shared

    var body: some View {
        Form {
            Section {
                Picker("Prefix", selection: Binding(
                    get: { prefixSelection },
                    set: updatePrefixSelection
                )) {
                    Text("Control-B").tag("^B")
                    Text("Control-A").tag("^A")
                    Text("Custom").tag("custom")
                }

                if prefixSelection == "custom" {
                    TextField("Prefix, e.g. \\x02", text: $customPrefix)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(saveCustomPrefix)
                }
            } header: {
                Text("tmux Prefix")
            } footer: {
                Text("Use ^B, ^A, \\e, or a two-digit byte such as \\x02.")
            }

            Section {
                if configuration.customCommands.isEmpty {
                    Text("No custom shortcuts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(configuration.customCommands) { command in
                        Button {
                            editingCommand = command
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(command.title)
                                    .foregroundStyle(.primary)
                                Text(command.sequence)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteCommands)
                }

                Button {
                    editingCommand = TmuxCommand(title: "", sequence: "")
                } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
            } header: {
                Text("Custom Shortcuts")
            } footer: {
                Text("Shortcuts can send arbitrary UTF-8 text, control keys, escape sequences, and hexadecimal bytes.")
            }

            if let presentedError {
                Section {
                    ErrorPresentationView(presentation: presentedError)
                }
            }
        }
        .navigationTitle("tmux Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            customPrefix = configuration.prefix
        }
        .sheet(item: $editingCommand) { command in
            TmuxCommandEditorView(command: command)
        }
    }

    private var prefixSelection: String {
        switch configuration.prefix {
        case "^A", "^B": configuration.prefix
        default: "custom"
        }
    }

    private func updatePrefixSelection(_ selection: String) {
        presentedError = nil
        if selection == "custom" {
            customPrefix = "\\x02"
            saveCustomPrefix()
            return
        }

        do {
            try configuration.setPrefix(selection)
            customPrefix = selection
        } catch {
            presentedError = ErrorPresentation.classify(error, context: ErrorContext(operation: .tmux))
        }
    }

    private func saveCustomPrefix() {
        do {
            try configuration.setPrefix(customPrefix)
            presentedError = nil
        } catch {
            presentedError = ErrorPresentation.classify(error, context: ErrorContext(operation: .tmux))
        }
    }

    private func deleteCommands(at offsets: IndexSet) {
        for index in offsets {
            configuration.removeCustomCommand(id: configuration.customCommands[index].id)
        }
    }
}

private struct TmuxCommandEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var detail: String
    @State private var sequence: String
    @State private var sendsPrefix: Bool
    @State private var presentedError: ErrorPresentation?

    private let id: String
    private let configuration = TmuxConfigurationService.shared

    init(command: TmuxCommand) {
        id = command.id
        _title = State(initialValue: command.title)
        _detail = State(initialValue: command.detail)
        _sequence = State(initialValue: command.sequence)
        _sendsPrefix = State(initialValue: command.sendsPrefix)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Shortcut") {
                    TextField("Name", text: $title)
                    TextField("Description (optional)", text: $detail)
                    TextField("Sequence, e.g. \\e[1;5A", text: $sequence)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Send tmux prefix first", isOn: $sendsPrefix)
                }

                Section {
                    Text("^B sends Control-B. \\e sends Escape. \\n, \\r, and \\t send newline, return, and tab. \\x1b sends a hexadecimal byte.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let presentedError {
                    Section {
                        ErrorPresentationView(presentation: presentedError)
                    }
                }
            }
            .navigationTitle("Custom Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sequence.isEmpty)
                }
            }
        }
    }

    private func save() {
        let command = TmuxCommand(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            sequence: sequence,
            sendsPrefix: sendsPrefix
        )

        do {
            try configuration.saveCustomCommand(command)
            dismiss()
        } catch {
            presentedError = ErrorPresentation.classify(error, context: ErrorContext(operation: .tmux))
        }
    }
}
