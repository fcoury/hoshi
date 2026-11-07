import SwiftUI

// MARK: - Custom key editor

/// A custom key being created or edited in the toolbar editor.
struct CustomKeyDraft: Identifiable {
    let id: String
    var label: String
    var chord: String
    var symbol: String
    let isNew: Bool

    init() {
        id = ToolbarButton.customIDPrefix + UUID().uuidString
        label = ""
        chord = ""
        symbol = ""
        isNew = true
    }

    init(editing button: ToolbarButton) {
        id = button.id
        label = button.label
        chord = button.chord ?? ""
        symbol = button.symbol ?? ""
        isNew = false
    }
}

struct CustomKeyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomKeyDraft
    let prefix: String?
    let onSave: (ToolbarButton) -> Void

    init(draft: CustomKeyDraft, prefix: String?, onSave: @escaping (ToolbarButton) -> Void) {
        _draft = State(initialValue: draft)
        self.prefix = prefix
        self.onSave = onSave
    }

    private static let quickTokens = [
        "prefix+", "ctrl+", "alt+", "shift+", "esc", "enter", "tab", "space",
        "up", "down", "left", "right",
    ]

    private var encoding: Result<[UInt8], Error> {
        Result { try KeyChord.encode(draft.chord, prefix: prefix) }
    }

    private var trimmedLabel: String {
        draft.label.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        !trimmedLabel.isEmpty && (try? encoding.get()) != nil
    }

    private var previewButton: ToolbarButton {
        .custom(
            label: trimmedLabel.isEmpty ? "Key" : trimmedLabel,
            chord: draft.chord,
            symbol: draft.symbol.isEmpty ? nil : draft.symbol,
            id: draft.id
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ToolbarKeyGlyph(button: previewButton)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .frame(minWidth: 48, minHeight: 40)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(AppearanceSettings.shared.currentTheme.cardSurface))
                            )
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Label") {
                    TextField("e.g. Split", text: $draft.label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom.key.label")
                }

                Section {
                    TextField("e.g. prefix+d or esc : w enter", text: $draft.chord)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom.key.chord")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.quickTokens, id: \.self) { token in
                                Button(token) { insert(token) }
                                    .font(.caption.monospaced())
                                    .buttonStyle(.bordered)
                                    .disabled(token == "prefix+" && prefix == nil)
                            }
                        }
                    }

                    encodingRow
                } header: {
                    Text("Keys to Send")
                } footer: {
                    Text(chordHelp)
                }

                Section {
                    HStack {
                        TextField("SF Symbol name (optional)", text: $draft.symbol)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !draft.symbol.isEmpty {
                            Image(systemName: draft.symbol)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Icon")
                } footer: {
                    Text("Shown instead of the label, e.g. rectangle.split.2x1.")
                }
            }
            .navigationTitle(draft.isNew ? "New Key" : "Edit Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isNew ? "Add" : "Save") {
                        onSave(.custom(
                            label: trimmedLabel,
                            chord: draft.chord.trimmingCharacters(in: .whitespaces),
                            symbol: draft.symbol.isEmpty ? nil : draft.symbol,
                            id: draft.id
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var encodingRow: some View {
        if draft.chord.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else {
            switch encoding {
            case .success(let bytes):
                LabeledContent("Sends") {
                    Text(Self.describe(bytes))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var chordHelp: String {
        let prefixText = prefix.map { "“prefix” sends \(KeyChord.displayString($0)). " } ?? ""
        return prefixText + "Separate keys with spaces. Words that aren't key names are typed as text."
    }

    private func insert(_ token: String) {
        let needsSpace = !draft.chord.isEmpty && !draft.chord.hasSuffix(" ") && !draft.chord.hasSuffix("+")
        draft.chord += (needsSpace ? " " : "") + token
    }

    /// Readable byte preview: printable ASCII as-is, control bytes in caret/hex form.
    static func describe(_ bytes: [UInt8]) -> String {
        bytes.map { byte -> String in
            switch byte {
            case 0x1B: return "ESC"
            case 0x0D: return "CR"
            case 0x09: return "TAB"
            case 0x7F: return "DEL"
            case 0x20: return "SP"
            case 0x00..<0x20: return "^" + String(UnicodeScalar(byte + 0x40))
            case 0x21..<0x7F: return String(UnicodeScalar(byte))
            default: return String(format: "%02X", byte)
            }
        }
        .joined(separator: " ")
    }
}

// MARK: - Key set settings

struct KeySetSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: KeyProfile

    @State private var patternsText = ""
    @State private var prefixText = ""

    private var hasPrefix: Bool {
        profile.prefix != nil || profile.id == KeyProfile.herdrID || profile.id == KeyProfile.tmuxID
    }

    private var prefixError: String? {
        let trimmed = prefixText.trimmingCharacters(in: .whitespaces)
        guard hasPrefix, !trimmed.isEmpty else { return nil }
        do {
            _ = try KeyChord.encode(trimmed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. vim, nvim", text: $patternsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("keyset.patterns")
                } header: {
                    Text("Switch Automatically When Title Contains")
                } footer: {
                    Text("Comma-separated words matched against the terminal title. Long-press any toolbar key to pin a key set for a server.")
                }

                if hasPrefix {
                    Section {
                        TextField("ctrl+b", text: $prefixText)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("keyset.prefix")
                        if let prefixError {
                            Label(prefixError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Prefix")
                    } footer: {
                        Text(profile.id == KeyProfile.herdrID
                            ? "Keys that start with “prefix” send this first. Importing config.toml sets it from the server."
                            : "Keys that start with “prefix” send this first.")
                    }
                }
            }
            .navigationTitle("\(profile.name) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(prefixError != nil)
                }
            }
            .onAppear {
                patternsText = profile.matchPatterns.joined(separator: ", ")
                prefixText = profile.prefix ?? ""
            }
        }
    }

    private func apply() {
        profile.matchPatterns = patternsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if hasPrefix {
            let trimmed = prefixText.trimmingCharacters(in: .whitespaces)
            profile.prefix = trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Settings list

/// Settings › Keyboard & Gestures › Key Sets.
struct KeySetsSettingsView: View {
    private let store = KeyProfileStore.shared
    @State private var editingProfileID: EditingProfile?

    private struct EditingProfile: Identifiable {
        let id: String
    }

    var body: some View {
        Form {
            Section {
                Toggle("Switch Automatically", isOn: Binding(
                    get: { store.autoSwitch },
                    set: { store.autoSwitch = $0 }
                ))
            } footer: {
                Text("Hoshi picks a key set from the terminal title, e.g. Vim keys while vim is running. Hold any toolbar key to pin a key set for a server.")
            }

            Section("Key Sets") {
                ForEach(store.profiles) { profile in
                    Button {
                        editingProfileID = EditingProfile(id: profile.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: profile.symbol)
                                .frame(width: 24)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .foregroundStyle(.primary)
                                Text(subtitle(for: profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("keysets.\(profile.id)")
                }
            }
        }
        .navigationTitle("Key Sets")
        .sheet(item: $editingProfileID) { editing in
            ToolbarEditView(profileID: editing.id)
        }
    }

    private func subtitle(for profile: KeyProfile) -> String {
        if profile.isShell { return "Default toolbar" }
        let words = profile.matchPatterns.prefix(4).joined(separator: ", ")
        var parts: [String] = []
        if !words.isEmpty { parts.append(words) }
        if let prefix = profile.prefix { parts.append("prefix \(KeyChord.displayString(prefix))") }
        return parts.joined(separator: " · ")
    }
}
