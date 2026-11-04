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
        ToolbarButton.allAvailable.filter { $0.category == selectedCategory }
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
                KeySetSettingsSheet(
                    profile: $profile,
                    currentButtons: $currentButtons,
                    serverName: serverName,
                    herdrConfigLoader: herdrConfigLoader
                )
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
                buttons: currentButtons,
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

                    ForEach(ToolbarButton.Category.allCases, id: \.self) { category in
                        categoryPill(category)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Grid of buttons for selected category
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 10) {
                    ForEach(categoryButtons) { button in
                        let alreadyAdded = currentIDs.contains(button.id)
                        Button {
                            guard !alreadyAdded else { return }
                            withAnimation {
                                currentButtons.append(button)
                            }
                        } label: {
                            ToolbarKeyGlyph(button: button)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(minWidth: 50, minHeight: 36)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(SwiftUI.Color(editTheme.cardSurface))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(SwiftUI.Color(editTheme.separator), lineWidth: 0.5)
                                )
                                .opacity(alreadyAdded ? 0.4 : 1.0)
                        }
                        .disabled(alreadyAdded)
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
