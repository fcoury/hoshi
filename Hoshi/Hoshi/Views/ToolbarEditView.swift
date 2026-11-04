import SwiftUI

// Two-zone toolbar editor: top zone previews and orders the current layout,
// while the bottom zone shows available keys.
struct ToolbarEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var profile: KeyProfile
    @State private var currentButtons: [ToolbarButton]
    @State private var selectedCategory: ToolbarButton.Category = .modifier
    @State private var showResetAlert = false
    @State private var draggingButton: ToolbarButton?
    @State private var customKeyDraft: CustomKeyDraft?
    @State private var showKeySetSettings = false
    @State private var isImportingHerdr = false
    @State private var herdrImportMessage: String?
    @State private var herdrImportFailed = false

    private let serverName: String?
    private let herdrConfigLoader: (() async throws -> String?)?

    // Callback to refresh the toolbar after saving
    var onSave: (() -> Void)?

    /// - Parameters:
    ///   - profileID: Key set to edit; defaults to the Shell toolbar.
    ///   - serverName: Connected server, used to label the Herdr import action.
    ///   - herdrConfigLoader: Reads the server's Herdr config.toml; nil when not connected.
    init(
        profileID: String = KeyProfile.shellID,
        serverName: String? = nil,
        herdrConfigLoader: (() async throws -> String?)? = nil,
        onSave: (() -> Void)? = nil
    ) {
        let store = KeyProfileStore.shared
        let profile = store.profile(id: profileID) ?? store.shell
        _profile = State(initialValue: profile)
        _currentButtons = State(initialValue: profile.keys)
        _selectedCategory = State(initialValue: profile.id == KeyProfile.herdrID ? .herdr : .modifier)
        self.serverName = serverName
        self.herdrConfigLoader = herdrConfigLoader
        self.onSave = onSave
    }

    private func save() {
        var updated = profile
        updated.keys = currentButtons
        KeyProfileStore.shared.update(updated)
    }

    // All buttons for the selected category, with already-added ones dimmed
    private var categoryButtons: [ToolbarButton] {
        if selectedCategory == .herdr {
            return HerdrKeyImport.catalog.map(HerdrKeyImport.button(for:))
        }
        return ToolbarButton.allAvailable.filter { $0.category == selectedCategory }
    }

    private var isHerdrProfile: Bool { profile.id == KeyProfile.herdrID }

    /// The Herdr tab only makes sense where Herdr's prefix and bindings apply.
    private var visibleCategories: [ToolbarButton.Category] {
        let others = ToolbarButton.Category.allCases.filter { $0 != .herdr }
        return isHerdrProfile ? [.herdr] + others : others
    }

    /// Current edits as a key set, for binding lookups and the live preview.
    private var draftProfile: KeyProfile {
        var draft = profile
        draft.keys = currentButtons
        return draft
    }

    private func herdrBinding(_ button: ToolbarButton) -> String? {
        guard let action = button.herdrAction else { return nil }
        return HerdrKeyImport.binding(for: action, bindings: profile.herdrBindings, prefix: profile.prefix)
    }

    private func isUnbound(_ button: ToolbarButton) -> Bool {
        button.herdrAction != nil && herdrBinding(button) == nil
    }

    private var currentIDs: Set<String> {
        Set(currentButtons.map(\.id))
    }

    // Short display names for category tabs
    private func categoryLabel(_ category: ToolbarButton.Category) -> String {
        switch category {
        case .modifier:   return "Mod"
        case .navigation: return "Nav"
        case .swipe:      return "Swipe"
        case .function:   return "Fn"
        case .symbol:     return "Sym"
        case .clipboard:  return "Clip"
        case .transfer:   return "Files"
        case .voice:      return "Voice"
        case .combo:      return "Cmb"
        case .herdr:      return "Herdr"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top zone: live preview and key order
                yourToolbarSection

                Divider()

                // Bottom zone: "Available Keys"
                availableKeysSection
            }
            .background(SwiftUI.Color(AppearanceSettings.shared.currentTheme.chromeBackground))
            .navigationTitle(profile.isShell ? "Edit Toolbar" : "\(profile.name) Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !profile.isShell {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showKeySetSettings = true
                        } label: {
                            Label("Key Set Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("toolbar.editor.keyset.settings")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        onSave?()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert(profile.isShell ? "Reset Toolbar?" : "Reset \(profile.name) Keys?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    HapticService.warning()
                    withAnimation {
                        KeyProfileStore.shared.reset(id: profile.id)
                        if let restored = KeyProfileStore.shared.profile(id: profile.id) {
                            profile = restored
                            currentButtons = restored.keys
                        }
                    }
                }
            } message: {
                Text(profile.isShell
                    ? "This will restore the default toolbar layout."
                    : "This restores the built-in keys, prefix and title words for \(profile.name).")
            }
            .sheet(item: $customKeyDraft) { draft in
                CustomKeyEditorSheet(draft: draft, prefix: profile.prefix) { button in
                    withAnimation {
                        if let index = currentButtons.firstIndex(where: { $0.id == button.id }) {
                            currentButtons[index] = button
                        } else {
                            currentButtons.append(button)
                        }
                    }
                }
            }
            .sheet(isPresented: $showKeySetSettings) {
                KeySetSettingsSheet(profile: $profile)
            }
        }
    }

    // MARK: - Top zone: current toolbar preview and layout

    private var yourToolbarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LIVE PREVIEW")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            KeyboardToolbarContent(
                buttons: draftProfile.resolvedKeys,
                activeModifiers: [],
                selectionAvailable: true,
                pasteAvailable: true,
                voicePromptAvailable: true,
                onButtonTap: { _ in },
                onSwipeArrow: { _ in },
                onEditTap: {},
                onDismissKeyboard: {}
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(editTheme.separator), lineWidth: 0.5)
            }
            .clipShape(.rect(cornerRadius: 8))
            .padding(.horizontal, 16)

            Text("KEY ORDER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .padding(.horizontal, 16)

            if currentButtons.isEmpty {
                // Empty state
                Text("Tap keys below to add them")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                // Scrollable row of button chips with x badges
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(currentButtons) { button in
                            toolbarChip(button)
                                .opacity(draggingButton?.id == button.id ? 0.3 : 1)
                                .onDrag {
                                    draggingButton = button
                                    return NSItemProvider(object: button.id as NSString)
                                }
                                .onDrop(of: [.text], delegate: ButtonDropDelegate(
                                    button: button,
                                    currentButtons: $currentButtons,
                                    draggingButton: $draggingButton
                                ))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Text("Long-press & drag to reorder · tap a custom key to edit it")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    private var editTheme: TerminalTheme { AppearanceSettings.shared.currentTheme }

    // A single chip in the "Your Toolbar" row with an x badge
    private func toolbarChip(_ button: ToolbarButton) -> some View {
        ZStack(alignment: .topTrailing) {
            ToolbarKeyGlyph(button: button)
                .opacity(isUnbound(button) ? 0.45 : 1)
                .onTapGesture {
                    guard button.isCustom else { return }
                    customKeyDraft = CustomKeyDraft(editing: button)
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(SwiftUI.Color(editTheme.cardSurface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SwiftUI.Color(editTheme.separator), lineWidth: 0.5)
                )

            // X badge to remove
            Button {
                withAnimation {
                    currentButtons.removeAll { $0.id == button.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(SwiftUI.Color(editTheme.chromeBackground)).padding(2))
            }
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6)
    }

    // MARK: - Bottom zone: available keys palette

    private var availableKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AVAILABLE KEYS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            // Pill-shaped category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        customKeyDraft = CustomKeyDraft()
                    } label: {
                        Label("Custom", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(SwiftUI.Color(editTheme.cardSurface)))
                            .overlay(Capsule().strokeBorder(SwiftUI.Color(editTheme.accentBlue), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("toolbar.editor.custom.add")

                    ForEach(visibleCategories, id: \.self) { category in
                        categoryPill(category)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Grid of buttons for selected category
            ScrollView {
                if selectedCategory == .herdr {
                    herdrImportHeader
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: selectedCategory == .herdr ? 96 : 70))], spacing: 10) {
                    ForEach(categoryButtons) { button in
                        let alreadyAdded = currentIDs.contains(button.id)
                        let unbound = isUnbound(button)
                        Button {
                            guard !alreadyAdded else { return }
                            withAnimation {
                                currentButtons.append(button)
                            }
                        } label: {
                            VStack(spacing: 2) {
                                ToolbarKeyGlyph(button: button)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                if button.herdrAction != nil {
                                    Text(herdrBinding(button).map(KeyChord.displayString) ?? "unbound")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minWidth: 50, minHeight: 36)
                            .padding(.horizontal, 8)
                            .padding(.vertical, button.herdrAction != nil ? 4 : 0)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(SwiftUI.Color(editTheme.cardSurface))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(SwiftUI.Color(editTheme.separator), lineWidth: 0.5)
                            )
                            .opacity(alreadyAdded ? 0.4 : (unbound ? 0.55 : 1.0))
                        }
                        .buttonStyle(.plain)
                        .disabled(alreadyAdded)
                        .accessibilityLabel(button.herdrAction != nil
                            ? "\(button.label), \(herdrBinding(button).map(KeyChord.displayString) ?? "unbound")"
                            : button.accessibilityLabel)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Reset to defaults button
            Button {
                showResetAlert = true
            } label: {
                Text("Reset to Defaults")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 12)
    }

    // MARK: - Herdr bindings

    private var herdrStatusText: String {
        if let source = profile.herdrBindingsSource, let date = profile.herdrImportedAt {
            let when = date.formatted(.relative(presentation: .named))
            return "Bindings from \(source) · \(when) · prefix \(KeyChord.displayString(profile.prefix ?? HerdrKeyImport.defaultPrefix))"
        }
        if profile.herdrBindings != nil {
            return "Imported bindings · prefix \(KeyChord.displayString(profile.prefix ?? HerdrKeyImport.defaultPrefix))"
        }
        return "Herdr default bindings · prefix \(KeyChord.displayString(profile.prefix ?? HerdrKeyImport.defaultPrefix))"
    }

    private var herdrImportHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(herdrStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if isImportingHerdr {
                    ProgressView().controlSize(.small)
                } else if herdrConfigLoader != nil {
                    Button(profile.herdrBindings == nil ? "Import" : "Re-import") {
                        Task { await importHerdrBindings() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("toolbar.editor.herdr.import")
                }
            }
            if let herdrImportMessage {
                Text(herdrImportMessage)
                    .font(.caption2)
                    .foregroundStyle(herdrImportFailed ? .orange : .secondary)
            } else if herdrConfigLoader == nil {
                Text("Open this editor from a connected terminal to import config.toml.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Refreshes the prefix and bindings from the server; the chosen keys stay as they are.
    private func importHerdrBindings() async {
        guard let herdrConfigLoader else { return }
        isImportingHerdr = true
        defer { isImportingHerdr = false }
        do {
            let config = try await herdrConfigLoader()
            let result = HerdrKeyImport.importConfig(config)
            withAnimation {
                profile.prefix = result.prefix
                profile.herdrBindings = result.bindings
                profile.herdrBindingsSource = serverName
                profile.herdrImportedAt = Date()
            }
            // Persist now so the import survives dismissing the editor without Done.
            KeyProfileStore.shared.updateHerdrBindings(
                prefix: result.prefix,
                bindings: result.bindings,
                source: serverName
            )
            herdrImportFailed = false
            herdrImportMessage = config == nil
                ? "No config.toml on the server — using Herdr's defaults."
                : "Imported prefix \(KeyChord.displayString(result.prefix)) and \(result.configuredActionCount) customized actions."
            HapticService.success()
        } catch {
            herdrImportFailed = true
            herdrImportMessage = "Couldn't read config.toml: \(error.localizedDescription)"
            HapticService.error()
        }
    }

    // Pill-shaped category tab
    private func categoryPill(_ category: ToolbarButton.Category) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            Text(categoryLabel(category))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? SwiftUI.Color.black : SwiftUI.Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? SwiftUI.Color.white : SwiftUI.Color(editTheme.cardSurface))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(SwiftUI.Color(editTheme.separator), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Drag & drop reorder delegate

private struct ButtonDropDelegate: DropDelegate {
    let button: ToolbarButton
    @Binding var currentButtons: [ToolbarButton]
    @Binding var draggingButton: ToolbarButton?

    func performDrop(info: DropInfo) -> Bool {
        draggingButton = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingButton,
              dragging.id != button.id,
              let fromIndex = currentButtons.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = currentButtons.firstIndex(where: { $0.id == button.id })
        else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            currentButtons.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
