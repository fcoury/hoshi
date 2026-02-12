import SwiftUI

// Edit mode for customizing the keyboard toolbar layout
// Supports drag-to-reorder, remove, and add from palette
struct ToolbarEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentButtons: [ToolbarButton]
    @State private var selectedCategory: ToolbarButton.Category = .modifier

    // Callback to refresh the toolbar after saving
    var onSave: (() -> Void)?

    init(onSave: (() -> Void)? = nil) {
        let buttons = ToolbarConfigurationService.shared.loadButtons()
        _currentButtons = State(initialValue: buttons)
        self.onSave = onSave
    }

    // Buttons not yet in the toolbar, filtered by selected category
    private var availableButtons: [ToolbarButton] {
        let currentIDs = Set(currentButtons.map(\.id))
        return ToolbarButton.allAvailable.filter {
            $0.category == selectedCategory && !currentIDs.contains($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Current toolbar layout — reorderable and deletable
                Section {
                    ForEach(currentButtons) { button in
                        HStack {
                            Text(button.label)
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 40)
                            Text(button.category.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .onMove(perform: moveButtons)
                    .onDelete(perform: removeButtons)
                } header: {
                    Text("Current Toolbar")
                } footer: {
                    Text("Drag to reorder. Swipe to remove.")
                }

                // Available buttons palette
                Section {
                    // Category picker
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(ToolbarButton.Category.allCases, id: \.self) { category in
                            Text(category.rawValue.capitalized).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(SwiftUI.Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                    if availableButtons.isEmpty {
                        Text("All buttons in this category are already added.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        // Grid of available buttons to add
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                            ForEach(availableButtons) { button in
                                Button {
                                    withAnimation {
                                        currentButtons.append(button)
                                    }
                                } label: {
                                    Text(button.label)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .frame(minWidth: 44, minHeight: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(SwiftUI.Color(UIColor.tertiarySystemBackground))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(SwiftUI.Color(UIColor.separator), lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                        .listRowBackground(SwiftUI.Color.clear)
                    }
                } header: {
                    Text("Add Buttons")
                }

                // Reset to defaults
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        withAnimation {
                            ToolbarConfigurationService.shared.resetToDefaults()
                            currentButtons = ToolbarButton.defaultButtons
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Toolbar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        ToolbarConfigurationService.shared.saveButtons(currentButtons)
                        onSave?()
                        dismiss()
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func moveButtons(from source: IndexSet, to destination: Int) {
        currentButtons.move(fromOffsets: source, toOffset: destination)
    }

    private func removeButtons(at offsets: IndexSet) {
        currentButtons.remove(atOffsets: offsets)
    }
}
