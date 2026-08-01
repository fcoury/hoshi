import AVFoundation
import Foundation
import Speech

enum VoicePromptAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var displayName: String {
        switch self {
        case .notDetermined: "Not Requested"
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        }
    }
}

enum VoicePromptRecordingState: Equatable, Sendable {
    case idle
    case requestingAuthorization
    case recording
    case editing
}

enum VoicePromptError: LocalizedError, Equatable {
    case disabled
    case microphoneDenied
    case microphoneRestricted
    case speechDenied
    case speechRestricted
    case onDeviceRecognitionUnavailable
    case recognizerUnavailable
    case audioUnavailable
    case emptyDraft
    case draftTooLarge(maximumBytes: Int)
    case unsafeControlCharacters

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Enable Voice Prompts in Hoshi Settings."
        case .microphoneDenied:
            "Allow microphone access for Hoshi in iOS Settings."
        case .microphoneRestricted:
            "Microphone access is restricted on this device."
        case .speechDenied:
            "Allow speech recognition for Hoshi in iOS Settings."
        case .speechRestricted:
            "Speech recognition is restricted on this device."
        case .onDeviceRecognitionUnavailable:
            "On-device speech recognition is unavailable for this language. Install its dictation model in iOS Settings or choose another language."
        case .recognizerUnavailable:
            "Speech recognition is temporarily unavailable."
        case .audioUnavailable:
            "The microphone could not start. Check whether another app is using it."
        case .emptyDraft:
            "Speak or type a prompt before sending it to the terminal."
        case .draftTooLarge(let maximumBytes):
            "The prompt exceeds its \(maximumBytes.formatted())-byte limit."
        case .unsafeControlCharacters:
            "Remove terminal control characters from the prompt before sending it."
        }
    }
}

enum VoicePromptRecognitionUpdate: Equatable, Sendable {
    case transcript(String, isFinal: Bool)
    case failed(String)
}

@MainActor
protocol VoicePromptRecognizing: AnyObject {
    var speechAuthorization: VoicePromptAuthorizationStatus { get }
    var microphoneAuthorization: VoicePromptAuthorizationStatus { get }

    func requestSpeechAuthorization() async -> VoicePromptAuthorizationStatus
    func requestMicrophoneAuthorization() async -> VoicePromptAuthorizationStatus
    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool
    func isAvailable(localeIdentifier: String) -> Bool
    func startRecognition(
        localeIdentifier: String,
        onUpdate: @escaping @Sendable (VoicePromptRecognitionUpdate) -> Void
    ) throws
    func stopRecognition()
    func cancelRecognition()
}

/// Speech and AVAudio capture are retained only while a deliberately started recording is active.
@MainActor
final class SystemVoicePromptRecognizer: VoicePromptRecognizing {
    private let audioSession: AVAudioSession
    private let audioEngine: AVAudioEngine
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeRecognizer: SFSpeechRecognizer?
    private var interruptionObserver: NSObjectProtocol?
    private var updateHandler: (@Sendable (VoicePromptRecognitionUpdate) -> Void)?
    private var hasInstalledAudioTap = false
    private var hasActivatedAudioSession = false

    init(
        audioSession: AVAudioSession = .sharedInstance(),
        audioEngine: AVAudioEngine = AVAudioEngine()
    ) {
        self.audioSession = audioSession
        self.audioEngine = audioEngine

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard rawValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, let handler = self.updateHandler else { return }
                self.cancelRecognition()
                handler(.failed("Recording was interrupted."))
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    var speechAuthorization: VoicePromptAuthorizationStatus {
        Self.mapSpeechAuthorization(SFSpeechRecognizer.authorizationStatus())
    }

    var microphoneAuthorization: VoicePromptAuthorizationStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .notDetermined
        case .granted: .authorized
        case .denied: .denied
        @unknown default: .restricted
        }
    }

    func requestSpeechAuthorization() async -> VoicePromptAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorization in
                continuation.resume(returning: Self.mapSpeechAuthorization(authorization))
            }
        }
    }

    func requestMicrophoneAuthorization() async -> VoicePromptAuthorizationStatus {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted ? .authorized : .denied)
            }
        }
    }

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
        recognizer(for: localeIdentifier)?.supportsOnDeviceRecognition == true
    }

    func isAvailable(localeIdentifier: String) -> Bool {
        recognizer(for: localeIdentifier)?.isAvailable == true
    }

    func startRecognition(
        localeIdentifier: String,
        onUpdate: @escaping @Sendable (VoicePromptRecognitionUpdate) -> Void
    ) throws {
        cancelRecognition()

        guard let recognizer = recognizer(for: localeIdentifier),
              recognizer.supportsOnDeviceRecognition else {
            throw VoicePromptError.onDeviceRecognitionUnavailable
        }
        guard recognizer.isAvailable else { throw VoicePromptError.recognizerUnavailable }

        let request = Self.makeOnDeviceRecognitionRequest()

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
            hasActivatedAudioSession = true

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoicePromptError.audioUnavailable
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasInstalledAudioTap = true

            audioEngine.prepare()
            try audioEngine.start()

            activeRecognizer = recognizer
            recognitionRequest = request
            updateHandler = onUpdate
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    onUpdate(.transcript(result.bestTranscription.formattedString, isFinal: result.isFinal))
                }
                if let error {
                    onUpdate(.failed(error.localizedDescription))
                }
            }
        } catch {
            cancelRecognition()
            if let error = error as? VoicePromptError { throw error }
            throw VoicePromptError.audioUnavailable
        }
    }

    func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        endAudioCapture()
    }

    func cancelRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        endAudioCapture()
    }

    private func endAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        if hasActivatedAudioSession {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            hasActivatedAudioSession = false
        }
        recognitionTask = nil
        recognitionRequest = nil
        activeRecognizer = nil
        updateHandler = nil
    }

    private func recognizer(for identifier: String) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }

    nonisolated static func makeOnDeviceRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        return request
    }

    nonisolated private static func mapSpeechAuthorization(
        _ authorization: SFSpeechRecognizerAuthorizationStatus
    ) -> VoicePromptAuthorizationStatus {
        switch authorization {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

enum VoicePromptRecordingLimit: Int, CaseIterable, Identifiable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .thirtySeconds: "30 Seconds"
        case .oneMinute: "1 Minute"
        case .twoMinutes: "2 Minutes"
        }
    }
}

@MainActor @Observable
final class VoicePromptSettings {
    static let shared = VoicePromptSettings()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let enabled = "app.gethoshi.voice-prompts.enabled"
        static let locale = "app.gethoshi.voice-prompts.locale"
        static let recordingLimit = "app.gethoshi.voice-prompts.recording-limit"
    }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Key.locale) }
    }

    var recordingLimit: VoicePromptRecordingLimit {
        didSet { defaults.set(recordingLimit.rawValue, forKey: Key.recordingLimit) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        localeIdentifier = defaults.string(forKey: Key.locale) ?? Locale.autoupdatingCurrent.identifier
        let savedLimit = defaults.integer(forKey: Key.recordingLimit)
        recordingLimit = VoicePromptRecordingLimit(rawValue: savedLimit) ?? .oneMinute
    }

    var availableLocaleIdentifiers: [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted { first, second in
                localeDisplayName(first).localizedStandardCompare(localeDisplayName(second)) == .orderedAscending
            }
    }

    func localeDisplayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct VoicePromptSubmission: Equatable, Sendable {
    static let maximumPromptBytes = 16_384

    enum Action: Equatable, Sendable {
        case insert
        case submit
    }

    let action: Action
    let text: String
    let data: Data
    let confirmationMessage: String?

    var requiresConfirmation: Bool { confirmationMessage != nil }

    init(draft: String, action: Action) throws {
        let text = draft
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw VoicePromptError.emptyDraft }
        guard text.utf8.count <= Self.maximumPromptBytes else {
            throw VoicePromptError.draftTooLarge(maximumBytes: Self.maximumPromptBytes)
        }
        let containsUnsafeControl = text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t"
        }
        guard !containsUnsafeControl else { throw VoicePromptError.unsafeControlCharacters }

        self.action = action
        self.text = text
        var data = Data(text.utf8)
        if action == .submit {
            data.append(0x0D)
        }
        self.data = data

        let pasteAssessment = TerminalPastePolicy.assess(text, bracketedPasteEnabled: false)
        if action == .submit {
            if pasteAssessment.requiresConfirmation {
                confirmationMessage = "\(pasteAssessment.confirmationMessage) A Return will also be sent."
            } else {
                confirmationMessage = "Send this prompt followed by Return? This may execute it in the active terminal."
            }
        } else {
            confirmationMessage = pasteAssessment.requiresConfirmation ? pasteAssessment.confirmationMessage : nil
        }
    }
}

/// Tracks the currently presented composer so app locking and backgrounding can erase volatile drafts.
@MainActor
final class VoicePromptPrivacyCoordinator {
    static let shared = VoicePromptPrivacyCoordinator()

    private weak var activeController: VoicePromptController?

    func activate(_ controller: VoicePromptController) {
        if activeController !== controller {
            activeController?.cancelAndDiscard()
        }
        activeController = controller
    }

    func deactivate(_ controller: VoicePromptController) {
        guard activeController === controller else { return }
        activeController = nil
        controller.cancelAndDiscard()
    }

    func protectSensitiveContent() {
        activeController?.cancelAndDiscard()
    }
}

@MainActor @Observable
final class VoicePromptController {
    @ObservationIgnored private let recognizer: any VoicePromptRecognizing
    @ObservationIgnored private let settings: VoicePromptSettings
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var recordingGeneration: UUID?
    @ObservationIgnored private var existingDraft = ""
    @ObservationIgnored private let recordingTimeout: Duration?

    private(set) var state: VoicePromptRecordingState = .idle
    private(set) var errorMessage: String?
    private(set) var lastTranscript = ""
    private(set) var authorizationRevision = 0
    var draft = ""

    init(
        recognizer: (any VoicePromptRecognizing)? = nil,
        settings: VoicePromptSettings? = nil,
        recordingTimeout: Duration? = nil
    ) {
        self.recognizer = recognizer ?? SystemVoicePromptRecognizer()
        self.settings = settings ?? .shared
        self.recordingTimeout = recordingTimeout
    }

    var isRecording: Bool { state == .recording }
    var isRequestingAuthorization: Bool { state == .requestingAuthorization }
    var speechAuthorization: VoicePromptAuthorizationStatus {
        _ = authorizationRevision
        return recognizer.speechAuthorization
    }
    var microphoneAuthorization: VoicePromptAuthorizationStatus {
        _ = authorizationRevision
        return recognizer.microphoneAuthorization
    }
    var supportsOnDeviceRecognition: Bool {
        recognizer.supportsOnDeviceRecognition(localeIdentifier: settings.localeIdentifier)
    }

    var canSend: Bool {
        !isRecording && !isRequestingAuthorization
            && (try? VoicePromptSubmission(draft: draft, action: .insert)) != nil
    }

    func beginRecording() {
        guard settings.isEnabled else {
            fail(VoicePromptError.disabled)
            return
        }
        guard !isRecording, !isRequestingAuthorization else { return }

        let generation = UUID()
        recordingGeneration = generation
        existingDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscript = ""
        errorMessage = nil
        state = .requestingAuthorization

        startTask = Task { [weak self] in
            await self?.authorizeAndStart(generation: generation)
        }
    }

    func finishRecording() {
        guard state == .recording || state == .requestingAuthorization else { return }

        recordingGeneration = nil
        startTask?.cancel()
        startTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        if state == .recording {
            recognizer.stopRecognition()
        }

        state = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .editing
    }

    func cancelAndDiscard() {
        recordingGeneration = nil
        startTask?.cancel()
        startTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        recognizer.cancelRecognition()
        existingDraft = ""
        lastTranscript = ""
        draft = ""
        errorMessage = nil
        state = .idle
    }

    func submission(action: VoicePromptSubmission.Action) throws -> VoicePromptSubmission {
        guard !isRecording, !isRequestingAuthorization else {
            throw VoicePromptError.recognizerUnavailable
        }
        return try VoicePromptSubmission(draft: draft, action: action)
    }

    func requestMicrophoneAuthorization() async {
        let result = await recognizer.requestMicrophoneAuthorization()
        authorizationRevision += 1
        if result == .denied { fail(VoicePromptError.microphoneDenied) }
        if result == .restricted { fail(VoicePromptError.microphoneRestricted) }
    }

    func requestSpeechAuthorization() async {
        let result = await recognizer.requestSpeechAuthorization()
        authorizationRevision += 1
        if result == .denied { fail(VoicePromptError.speechDenied) }
        if result == .restricted { fail(VoicePromptError.speechRestricted) }
    }

    private func authorizeAndStart(generation: UUID) async {
        let locale = settings.localeIdentifier

        guard recognizer.supportsOnDeviceRecognition(localeIdentifier: locale) else {
            fail(VoicePromptError.onDeviceRecognitionUnavailable, generation: generation)
            return
        }
        guard recognizer.isAvailable(localeIdentifier: locale) else {
            fail(VoicePromptError.recognizerUnavailable, generation: generation)
            return
        }

        let microphone = recognizer.microphoneAuthorization == .notDetermined
            ? await recognizer.requestMicrophoneAuthorization()
            : recognizer.microphoneAuthorization

        guard recordingGeneration == generation, !Task.isCancelled else { return }
        guard microphone == .authorized else {
            let error: VoicePromptError = microphone == .restricted ? .microphoneRestricted : .microphoneDenied
            fail(error, generation: generation)
            return
        }

        let speech = recognizer.speechAuthorization == .notDetermined
            ? await recognizer.requestSpeechAuthorization()
            : recognizer.speechAuthorization

        guard recordingGeneration == generation, !Task.isCancelled else { return }
        guard speech == .authorized else {
            let error: VoicePromptError = speech == .restricted ? .speechRestricted : .speechDenied
            fail(error, generation: generation)
            return
        }

        do {
            try recognizer.startRecognition(localeIdentifier: locale) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.handleRecognitionUpdate(update, generation: generation)
                }
            }

            guard recordingGeneration == generation, !Task.isCancelled else {
                recognizer.cancelRecognition()
                return
            }

            state = .recording
            let timeout = recordingTimeout ?? .seconds(settings.recordingLimit.rawValue)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled,
                      let self,
                      self.recordingGeneration == generation,
                      self.state == .recording else { return }
                self.finishRecording()
            }
        } catch {
            fail(error, generation: generation)
        }
    }

    private func handleRecognitionUpdate(_ update: VoicePromptRecognitionUpdate, generation: UUID) {
        guard recordingGeneration == generation, state == .recording else { return }

        switch update {
        case .transcript(let value, let isFinal):
            let transcript = Self.safeTranscript(value)
            guard !transcript.isEmpty else { return }
            lastTranscript = transcript
            draft = existingDraft.isEmpty ? transcript : "\(existingDraft) \(transcript)"
            if isFinal {
                finishRecording()
            }
        case .failed(let message):
            fail(message, generation: generation)
        }
    }

    private func fail(_ error: any Error, generation: UUID? = nil) {
        if let generation, recordingGeneration != generation { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        fail(message, generation: generation)
    }

    private func fail(_ message: String, generation: UUID? = nil) {
        if let generation, recordingGeneration != generation { return }
        recordingGeneration = nil
        startTask?.cancel()
        startTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        recognizer.cancelRecognition()
        state = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .editing
        errorMessage = message
    }

    nonisolated private static func safeTranscript(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
        }
        let cleaned = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.utf8.count > VoicePromptSubmission.maximumPromptBytes else { return cleaned }

        var result = ""
        var count = 0
        for character in cleaned {
            let bytes = String(character).utf8.count
            guard count + bytes <= VoicePromptSubmission.maximumPromptBytes else { break }
            result.append(character)
            count += bytes
        }
        return result
    }
}
