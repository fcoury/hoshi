import SwiftUI
import UIKit

/// Volatile push-to-talk draft. Recording and text are destroyed whenever its presentation ends.
struct VoicePromptComposerView: View {
    let onSend: (Data) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editorIsFocused: Bool

    @State private var controller: VoicePromptController
    @State private var pendingSubmission: VoicePromptSubmission?
    @State private var isSending = false
    @State private var isHoldingRecordButton = false

    private let settings = VoicePromptSettings.shared
    private let appLock = AppLockService.shared

    init(
        controller: VoicePromptController? = nil,
        onSend: @escaping (Data) async -> Void
    ) {
        _controller = State(initialValue: controller ?? VoicePromptController())
        self.onSend = onSend
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    privacyNotice
                    authorizationSection
                    recordingSection
                    draftSection

                    if let error = controller.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                submissionControls
            }
            .navigationTitle("Voice Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismissComposer()
                    }
                }
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { pendingSubmission != nil },
                    set: { presented in
                        if !presented { pendingSubmission = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingSubmission
            ) { submission in
                Button(submission.action == .submit ? "Send with Return" : "Insert Prompt") {
                    send(submission)
                }
                Button("Cancel", role: .cancel) { pendingSubmission = nil }
            } message: { submission in
                Text(submission.confirmationMessage ?? "Confirm this terminal action.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(controller.isRecording || controller.isRequestingAuthorization || isSending)
        .onAppear {
            VoicePromptPrivacyCoordinator.shared.activate(controller)
        }
        .onDisappear {
            VoicePromptPrivacyCoordinator.shared.deactivate(controller)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                dismissComposer()
            case .inactive where controller.isRecording:
                controller.cancelAndDiscard()
            default:
                break
            }
        }
        .onChange(of: appLock.isLocked) { _, locked in
            if locked { dismissComposer() }
        }
    }

    private var privacyNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("On-Device Dictation")
                    .font(.headline)
                Text("Audio and transcripts stay on this device. Drafts are never saved and nothing reaches the terminal until you confirm it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var authorizationSection: some View {
        if controller.microphoneAuthorization != .authorized
            || controller.speechAuthorization != .authorized {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set Up Private Dictation")
                    .font(.headline)

                if controller.microphoneAuthorization != .authorized {
                    Button("Allow Microphone") {
                        Task { await controller.requestMicrophoneAuthorization() }
                    }
                    .buttonStyle(.bordered)
                }

                if controller.speechAuthorization != .authorized {
                    Button("Allow Speech Recognition") {
                        Task { await controller.requestSpeechAuthorization() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var recordingSection: some View {
        VStack(spacing: 12) {
            recordingButton

            Text(recordingStatus)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(controller.isRecording ? .red : .secondary)
                .accessibilityIdentifier("voice.recording.status")

            Text("\(settings.localeDisplayName(settings.localeIdentifier)) · Max \(settings.recordingLimit.title.lowercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var recordingButton: some View {
        ZStack {
            Circle()
                .fill(controller.isRecording ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.15))
                .frame(width: 94, height: 94)

            Circle()
                .fill(controller.isRecording ? Color.red : Color.accentColor)
                .frame(width: 72, height: 72)

            Image(systemName: controller.isRecording ? "waveform" : "mic.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
        .scaleEffect(controller.isRecording && !reduceMotion ? 1.04 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.isRecording)
        .contentShape(.circle)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isHoldingRecordButton else { return }
                    isHoldingRecordButton = true
                    editorIsFocused = false
                    HapticService.lightTap()
                    controller.beginRecording()
                }
                .onEnded { _ in
                    guard isHoldingRecordButton else { return }
                    isHoldingRecordButton = false
                    controller.finishRecording()
                    HapticService.lightTap()
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(controller.isRecording ? "Stop recording voice prompt" : "Record voice prompt")
        .accessibilityHint("Touch and hold to dictate entirely on this device")
        .accessibilityIdentifier("voice.push-to-talk")
        .accessibilityAction {
            if controller.isRecording {
                controller.finishRecording()
            } else {
                controller.beginRecording()
            }
        }
    }

    private var recordingStatus: String {
        switch controller.state {
        case .idle: "Hold to Speak"
        case .requestingAuthorization: "Waiting for Permission"
        case .recording: "Listening on Device"
        case .editing: "Edit Your Prompt"
        }
    }

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Editable Draft")
                    .font(.headline)
                Spacer()
                Text("\(controller.draft.utf8.count.formatted()) / \(VoicePromptSubmission.maximumPromptBytes.formatted()) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $controller.draft)
                .focused($editorIsFocused)
                .frame(minHeight: 130)
                .padding(8)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12))
                .disabled(controller.isRecording || isSending)
                .accessibilityLabel("Editable voice prompt draft")
                .accessibilityIdentifier("voice.draft.editor")

            Text("Insert keeps the prompt editable in your terminal. Send with Return always asks for confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var submissionControls: some View {
        VStack(spacing: 10) {
            Button {
                prepareSubmission(action: .insert)
            } label: {
                Label("Insert into Terminal", systemImage: "text.insert")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canSend || isSending)
            .accessibilityHint("Adds the draft without pressing Return")
            .accessibilityIdentifier("voice.insert")

            Button {
                prepareSubmission(action: .submit)
            } label: {
                Label("Send with Return", systemImage: "arrow.turn.down.left")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!controller.canSend || isSending)
            .accessibilityHint("Requests confirmation before submitting the prompt")
            .accessibilityIdentifier("voice.submit")
        }
        .padding()
        .background(.regularMaterial)
    }

    private var confirmationTitle: String {
        pendingSubmission?.action == .submit ? "Submit Prompt to Terminal?" : "Insert Multiline Prompt?"
    }

    private func prepareSubmission(action: VoicePromptSubmission.Action) {
        do {
            let submission = try controller.submission(action: action)
            if submission.requiresConfirmation {
                pendingSubmission = submission
            } else {
                send(submission)
            }
        } catch {
            HapticService.error()
        }
    }

    private func send(_ submission: VoicePromptSubmission) {
        guard !isSending else { return }
        pendingSubmission = nil
        isSending = true

        Task {
            await onSend(submission.data)
            isSending = false
            controller.cancelAndDiscard()
            HapticService.success()
            dismiss()
        }
    }

    private func dismissComposer() {
        controller.cancelAndDiscard()
        dismiss()
    }
}

struct VoicePromptSettingsView: View {
    @Environment(\.openURL) private var openURL

    @State private var controller = VoicePromptController()
    @State private var availableLocales: [String] = []

    private let settings = VoicePromptSettings.shared

    var body: some View {
        Form {
            configurationSection
            permissionSection
            privacySection
        }
        .navigationTitle("Voice Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            var locales = settings.availableLocaleIdentifiers
            if !locales.contains(settings.localeIdentifier) {
                locales.insert(settings.localeIdentifier, at: 0)
            }
            availableLocales = locales
        }
    }

    private var configurationSection: some View {
        Section {
            Toggle("Enable Voice Prompts", isOn: Binding(
                get: { settings.isEnabled },
                set: { settings.isEnabled = $0 }
            ))

            Picker("Recognition Language", selection: Binding(
                get: { settings.localeIdentifier },
                set: { settings.localeIdentifier = $0 }
            )) {
                ForEach(availableLocales, id: \.self) { locale in
                    Text(settings.localeDisplayName(locale)).tag(locale)
                }
            }
            .disabled(!settings.isEnabled)

            Picker("Recording Limit", selection: Binding(
                get: { settings.recordingLimit },
                set: { settings.recordingLimit = $0 }
            )) {
                ForEach(VoicePromptRecordingLimit.allCases) { limit in
                    Text(limit.title).tag(limit)
                }
            }
            .disabled(!settings.isEnabled)

            LabeledContent("On-Device Recognition") {
                Text(controller.supportsOnDeviceRecognition ? "Available" : "Unavailable")
                    .foregroundStyle(controller.supportsOnDeviceRecognition ? .green : .secondary)
            }
        } header: {
            Text("Private Dictation")
        } footer: {
            Text("Only languages with an installed on-device recognition model are allowed. Hoshi never falls back to cloud transcription.")
        }
    }

    private var permissionSection: some View {
        Section {
            LabeledContent("Microphone", value: controller.microphoneAuthorization.displayName)
            LabeledContent("Speech Recognition", value: controller.speechAuthorization.displayName)

            if controller.microphoneAuthorization == .notDetermined {
                Button("Allow Microphone") {
                    Task { await controller.requestMicrophoneAuthorization() }
                }
            }

            if controller.speechAuthorization == .notDetermined {
                Button("Allow Speech Recognition") {
                    Task { await controller.requestSpeechAuthorization() }
                }
            }

            if controller.microphoneAuthorization == .denied || controller.speechAuthorization == .denied {
                Button("Open iOS Privacy Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Permissions are requested only when you choose to enable them or begin dictating.")
        }
    }

    private var privacySection: some View {
        Section {
            Label("On-device processing only", systemImage: "iphone")
            Label("No saved recordings or transcripts", systemImage: "internaldrive.badge.xmark")
            Label("Drafts cleared when Hoshi locks", systemImage: "lock.shield")
            Label("Return requires your confirmation", systemImage: "hand.raised")
        } header: {
            Text("Privacy & Safety")
        }
    }
}
