import SwiftUI

// All appearance controls: theme, font, cursor, opacity, color scheme.
struct AppearanceSettingsView: View {
    private let settings = AppearanceSettings.shared

    var body: some View {
        Form {
            themeSection
            fontSection
            cursorSection
            backgroundSection
            colorSchemeSection
        }
        .navigationTitle("Appearance")
    }

    // MARK: - Theme picker

    private var themeSection: some View {
        Section("Theme") {
            ForEach(TerminalTheme.allThemes) { theme in
                Button {
                    settings.themeID = theme.id
                } label: {
                    ThemeRow(theme: theme, isSelected: settings.themeID == theme.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Font

    private var fontSection: some View {
        Section("Font") {
            NavigationLink {
                FontPickerView()
            } label: {
                HStack {
                    Text("Font Family")
                    Spacer()
                    Text(settings.fontFamily)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Stepper(
                "Size: \(Int(settings.fontSize))pt",
                value: Binding(
                    get: { settings.fontSize },
                    set: { settings.fontSize = $0 }
                ),
                in: 8...32,
                step: 1
            )
        }
    }

    // MARK: - Cursor style

    private var cursorSection: some View {
        Section("Cursor") {
            Picker("Style", selection: Binding(
                get: { settings.cursorStyle },
                set: { settings.cursorStyle = $0 }
            )) {
                ForEach(CursorStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Background opacity

    private var backgroundSection: some View {
        Section("Background") {
            VStack(alignment: .leading) {
                Text("Opacity: \(Int(settings.backgroundOpacity * 100))%")
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

    // MARK: - Color scheme

    private var colorSchemeSection: some View {
        Section("Color Scheme") {
            Picker("Scheme", selection: Binding(
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
