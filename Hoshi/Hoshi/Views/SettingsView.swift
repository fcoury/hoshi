import SwiftUI

// Top-level settings navigation with an Appearance section.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label("Appearance", systemImage: "paintbrush")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
