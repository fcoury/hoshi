import SwiftUI

// Two-zone toolbar editor: top zone shows current layout, bottom zone shows available keys
struct ToolbarEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentButtons: [ToolbarButton]
    @State private var selectedCategory: ToolbarButton.Category = .modifier
    @State private var showResetAlert = false
    @State private var draggingButton: ToolbarButton?

    // Callback to refresh the toolbar after saving
    var onSave: (() -> Void)?

    init(onSave: (() -> Void)? = nil) {
        let buttons = ToolbarConfigurationService.shared.loadButtons()
        _currentButtons = State(initialValue: buttons)
        self.onSave = onSave
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
        case .combo:      return "Cmb"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top zone: "Your Toolbar"
                yourToolbarSection

                Divider()

                // Bottom zone: "Available Keys"
                availableKeysSection
            }
            .background(SwiftUI.Color(UIColor.systemGroupedBackground))
            .navigationTitle("Edit Toolbar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        ToolbarConfigurationService.shared.saveButtons(currentButtons)
                        onSave?()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Reset Toolbar?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    withAnimation {
                        ToolbarConfigurationService.shared.resetToDefaults()
                        currentButtons = ToolbarButton.defaultButtons
                    }
                }
            } message: {
                Text("This will restore the default toolbar layout.")
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Top zone: current toolbar layout

    private var yourToolbarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR TOOLBAR")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
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

            Text("Long-press & drag to reorder")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    // A single chip in the "Your Toolbar" row with an x badge
    private func toolbarChip(_ button: ToolbarButton) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(button.label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(SwiftUI.Color(UIColor.tertiarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SwiftUI.Color(UIColor.separator), lineWidth: 0.5)
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
                    .background(Circle().fill(SwiftUI.Color(UIColor.systemGroupedBackground)).padding(2))
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
                            Text(button.label)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(minWidth: 50, minHeight: 36)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(SwiftUI.Color(UIColor.tertiarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(SwiftUI.Color(UIColor.separator), lineWidth: 0.5)
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
                        .fill(isSelected ? SwiftUI.Color.white : SwiftUI.Color(UIColor.tertiarySystemBackground))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(SwiftUI.Color(UIColor.separator), lineWidth: 0.5)
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
