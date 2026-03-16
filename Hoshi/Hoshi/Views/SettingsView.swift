import SwiftUI

// Flat, scrollable settings page with section headers.
// Only populated sections are shown; future sections (Keyboard, Security) added when they have content.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settings = AppearanceSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                terminalSection
                appearanceSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        Section("Terminal") {
            // Font family picker
            NavigationLink {
                FontPickerView()
            } label: {
                HStack {
                    Text("Font Family")
                    Spacer()
                    Text(settings.fontFamily)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Font size stepper
            HStack {
                Text("Font Size")
                Spacer()
                Text("\(Int(settings.fontSize))pt")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                Stepper("", value: Binding(
                    get: { settings.fontSize },
                    set: { settings.fontSize = $0 }
                ), in: 8...32, step: 1)
                .labelsHidden()
            }

            // Color theme nav link
            NavigationLink {
                themePickerView
            } label: {
                HStack {
                    Text("Color Theme")
                    Spacer()
                    Text(settings.currentTheme.name)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Cursor style segmented picker
            Picker("Cursor Style", selection: Binding(
                get: { settings.cursorStyle },
                set: { settings.cursorStyle = $0 }
            )) {
                ForEach(CursorStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)

            // Scroll speed slider
            VStack(alignment: .leading) {
                HStack {
                    Text("Scroll Speed")
                    Spacer()
                    Text("\(String(format: "%.1f", settings.scrollMultiplier))x")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { settings.scrollMultiplier },
                        set: { settings.scrollMultiplier = $0 }
                    ),
                    in: 1...5,
                    step: 0.5
                )
            }

            // Background opacity slider
            VStack(alignment: .leading) {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text("\(Int(settings.backgroundOpacity * 100))%")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { settings.backgroundOpacity },
                        set: { settings.backgroundOpacity = $0 }
                    ),
                    in: 0...1,
                    step: 0.05
                )
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Color Scheme", selection: Binding(
                get: { settings.colorScheme },
                set: { settings.colorScheme = $0 }
            )) {
                ForEach(ColorSchemePreference.allCases) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Theme picker (pushed via NavigationLink)

    private var themePickerView: some View {
        List {
            ForEach(TerminalTheme.allThemes) { theme in
                Button {
                    settings.themeID = theme.id
                } label: {
                    ThemeRow(theme: theme, isSelected: settings.themeID == theme.id)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Color Theme")
    }
}

// MARK: - Theme row with color preview

private struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Mini color preview showing first 8 palette colors
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(theme.palette[index]))
                        .frame(width: 12, height: 20)
                }
            }
            .padding(4)
            .background(Color(theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(theme.name)
                .foregroundStyle(.primary)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }
}
