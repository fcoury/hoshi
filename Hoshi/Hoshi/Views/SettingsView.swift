import SwiftUI

// Flat, scrollable settings page with section headers.
// Only populated sections are shown; future sections (Keyboard, Security) added when they have content.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settings = AppearanceSettings.shared
    private let appLock = AppLockService.shared

    var body: some View {
        NavigationStack {
            Form {
                terminalSection
                keyboardSection
                agentSection
                securitySection
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

    // MARK: - Agent monitoring

    private var agentSection: some View {
        Section("Coding Agents") {
            NavigationLink {
                FileUploadSettingsView()
            } label: {
                Label("File Uploads", systemImage: "paperclip")
            }

            NavigationLink {
                VoicePromptSettingsView()
            } label: {
                Label("Voice Prompts", systemImage: "mic")
            }

            NavigationLink {
                AgentMonitoringSettingsView()
            } label: {
                HStack {
                    Text("Agent Monitoring")
                    Spacer()
                    let count = AgentEventCenter.shared.unreadCount
                    if count > 0 {
                        Text("\(count) unread")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                .accessibilityLabel("Terminal font size")
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
                    Text("\(settings.scrollMultiplier, format: .number.precision(.fractionLength(1)))x")
                        .font(.body.monospaced())
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

    // MARK: - Keyboard and gestures

    private var keyboardSection: some View {
        Section("Keyboard & Gestures") {
            NavigationLink {
                TmuxSettingsView()
            } label: {
                HStack {
                    Text("tmux Shortcuts")
                    Spacer()
                    Text(TmuxConfigurationService.shared.prefix)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Double Tap", selection: Binding(
                get: { settings.doubleTapAction },
                set: { settings.doubleTapAction = $0 }
            )) {
                ForEach(TerminalDoubleTapAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }

            Picker("Two-Finger Tap", selection: Binding(
                get: { settings.twoFingerTapAction },
                set: { settings.twoFingerTapAction = $0 }
            )) {
                ForEach(TerminalTwoFingerTapAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            Toggle("Require \(appLock.authenticationName)", isOn: Binding(
                get: { appLock.isEnabled },
                set: { enabled in
                    Task { await appLock.setEnabled(enabled) }
                }
            ))
            .disabled(!appLock.isAvailable && !appLock.isEnabled)

            if let presentation = appLock.presentedError {
                ErrorPresentationView(presentation: presentation)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("When enabled, Hoshi locks your terminal sessions whenever the app enters the background.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Color Scheme", selection: Binding(
                get: { settings.colorScheme },
                set: { settings.colorScheme = $0 }
            )) {
                ForEach(ColorSchemePreference.allCases) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Terminal colors follow your selected color theme. Choose Solarized Light for a light terminal.")
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
