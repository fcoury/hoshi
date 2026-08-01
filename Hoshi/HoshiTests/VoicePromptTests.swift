import Foundation
import Speech
import UIKit
import XCTest
@testable import Hoshi

@MainActor
final class VoicePromptTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: VoicePromptSettings!
    private var recognizer: MockVoicePromptRecognizer!
    private var previousToolbarButtons: [ToolbarButton] = []
    private var previousVoiceEnabled = true

    override func setUp() {
        super.setUp()
        suiteName = "hoshi.voice-prompt.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = VoicePromptSettings(defaults: defaults)
        recognizer = MockVoicePromptRecognizer()
        previousToolbarButtons = ToolbarConfigurationService.shared.loadButtons()
        previousVoiceEnabled = VoicePromptSettings.shared.isEnabled
        VoicePromptSettings.shared.isEnabled = true
        ToolbarConfigurationService.shared.resetToDefaults()
    }

    override func tearDown() {
        ToolbarConfigurationService.shared.saveButtons(previousToolbarButtons)
        VoicePromptSettings.shared.isEnabled = previousVoiceEnabled
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        recognizer = nil
        suiteName = nil
        super.tearDown()
    }

    func testVoiceSettingsDefaultToEnabledWithOneMinuteLimit() {
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.recordingLimit, .oneMinute)
        XCTAssertFalse(settings.localeIdentifier.isEmpty)
    }

    func testVoiceSettingsPersistOnlyConfiguration() {
        settings.isEnabled = false
        settings.localeIdentifier = "pt_BR"
        settings.recordingLimit = .twoMinutes

        let restored = VoicePromptSettings(defaults: defaults)

        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.localeIdentifier, "pt_BR")
        XCTAssertEqual(restored.recordingLimit, .twoMinutes)
        let savedVoiceKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("app.gethoshi.voice-prompts.")
        }
        XCTAssertEqual(savedVoiceKeys.count, 3)
    }

    func testRecordingRequiresEnabledVoicePrompts() async {
        settings.isEnabled = false
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.errorMessage, VoicePromptError.disabled.localizedDescription)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testCloudOnlyRecognizerFailsWithoutRequestingPermissions() async {
        recognizer.supportsOnDevice = false
        recognizer.microphoneAuthorization = .notDetermined
        recognizer.speechAuthorization = .notDetermined
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.errorMessage, VoicePromptError.onDeviceRecognitionUnavailable.localizedDescription)
        XCTAssertEqual(recognizer.microphoneRequestCount, 0)
        XCTAssertEqual(recognizer.speechRequestCount, 0)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testSystemRecognitionRequestRejectsCloudFallback() {
        let request = SystemVoicePromptRecognizer.makeOnDeviceRecognitionRequest()

        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertEqual(request.taskHint, .dictation)
    }

    func testUnavailableRecognizerFailsBeforeStartingMicrophone() async {
        recognizer.recognizerAvailable = false
        recognizer.microphoneAuthorization = .notDetermined
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.errorMessage, VoicePromptError.recognizerUnavailable.localizedDescription)
        XCTAssertEqual(recognizer.microphoneRequestCount, 0)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testUndeterminedPermissionsAreRequestedBeforeRecording() async {
        recognizer.microphoneAuthorization = .notDetermined
        recognizer.speechAuthorization = .notDetermined
        recognizer.microphoneRequestResult = .authorized
        recognizer.speechRequestResult = .authorized
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(recognizer.microphoneRequestCount, 1)
        XCTAssertEqual(recognizer.speechRequestCount, 1)
        XCTAssertEqual(recognizer.startCount, 1)
        controller.cancelAndDiscard()
    }

    func testDeniedMicrophoneNeverStartsSpeechRecognition() async {
        recognizer.microphoneAuthorization = .denied
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.errorMessage, VoicePromptError.microphoneDenied.localizedDescription)
        XCTAssertEqual(recognizer.speechRequestCount, 0)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testRestrictedMicrophoneProducesActionableError() async {
        recognizer.microphoneAuthorization = .restricted
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.errorMessage, VoicePromptError.microphoneRestricted.localizedDescription)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testDeniedSpeechPermissionNeverStartsRecording() async {
        recognizer.speechAuthorization = .denied
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.errorMessage, VoicePromptError.speechDenied.localizedDescription)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testRestrictedSpeechPermissionProducesActionableError() async {
        recognizer.speechAuthorization = .restricted
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.errorMessage, VoicePromptError.speechRestricted.localizedDescription)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testExplicitPermissionRequestsUpdateObservableState() async {
        recognizer.microphoneAuthorization = .notDetermined
        recognizer.speechAuthorization = .notDetermined
        let controller = makeController()

        await controller.requestMicrophoneAuthorization()
        await controller.requestSpeechAuthorization()

        XCTAssertEqual(controller.microphoneAuthorization, .authorized)
        XCTAssertEqual(controller.speechAuthorization, .authorized)
        XCTAssertEqual(controller.authorizationRevision, 2)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testAuthorizedRecordingStartsForSelectedLocale() async {
        settings.localeIdentifier = "pt_BR"
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(recognizer.startedLocale, "pt_BR")
        XCTAssertEqual(recognizer.startCount, 1)
        controller.cancelAndDiscard()
    }

    func testPartialTranscriptsUpdateEditableDraft() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()

        recognizer.emit(.transcript("Fix the flaky keyboard test", isFinal: false))
        await settle()

        XCTAssertEqual(controller.draft, "Fix the flaky keyboard test")
        XCTAssertEqual(controller.lastTranscript, "Fix the flaky keyboard test")
        XCTAssertTrue(controller.isRecording)
        controller.cancelAndDiscard()
    }

    func testNewRecordingAppendsToExistingEditableDraft() async {
        let controller = makeController()
        controller.draft = "Review the patch"
        controller.beginRecording()
        await settle()

        recognizer.emit(.transcript("and rerun the tests", isFinal: false))
        await settle()

        XCTAssertEqual(controller.draft, "Review the patch and rerun the tests")
        controller.cancelAndDiscard()
    }

    func testFinalTranscriptStopsRecordingWithoutSendingInput() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()

        recognizer.emit(.transcript("Wait for approval", isFinal: true))
        await settle()

        XCTAssertEqual(controller.state, .editing)
        XCTAssertEqual(controller.draft, "Wait for approval")
        XCTAssertEqual(recognizer.stopCount, 1)
    }

    func testFinishingWithoutSpeechReturnsToIdle() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()

        controller.finishRecording()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recognizer.stopCount, 1)
        XCTAssertFalse(controller.canSend)
    }

    func testFinishingRecordingKeepsDraftForExplicitReview() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()
        recognizer.emit(.transcript("Please investigate", isFinal: false))
        await settle()

        controller.finishRecording()

        XCTAssertEqual(controller.state, .editing)
        XCTAssertEqual(controller.draft, "Please investigate")
        XCTAssertTrue(controller.canSend)
        XCTAssertEqual(recognizer.stopCount, 1)
    }

    func testCancelingRecordingDeletesAudioAndTranscriptState() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()
        recognizer.emit(.transcript("Sensitive production details", isFinal: false))
        await settle()

        controller.cancelAndDiscard()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.draft, "")
        XCTAssertEqual(controller.lastTranscript, "")
        XCTAssertGreaterThanOrEqual(recognizer.cancelCount, 1)
    }

    func testLateRecognitionCallbacksCannotRestoreDiscardedDrafts() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()
        let staleHandler = recognizer.updateHandler

        controller.cancelAndDiscard()
        staleHandler?(.transcript("secret returned too late", isFinal: true))
        await settle()

        XCTAssertEqual(controller.draft, "")
        XCTAssertEqual(controller.state, .idle)
    }

    func testRepeatedBeginRecordingCannotStartTwice() async {
        let controller = makeController()

        controller.beginRecording()
        controller.beginRecording()
        await settle()
        controller.beginRecording()

        XCTAssertEqual(recognizer.startCount, 1)
        controller.cancelAndDiscard()
    }

    func testReleasedPushToTalkCannotStartAfterDelayedPermissionGrant() async {
        recognizer.microphoneAuthorization = .notDetermined
        recognizer.pauseMicrophoneAuthorization = true
        let controller = makeController()
        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.state, .requestingAuthorization)

        controller.finishRecording()
        recognizer.resumeMicrophoneAuthorization(with: .authorized)
        await settle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testMicrophoneStartupFailuresSurfaceActionableError() async {
        recognizer.startError = VoicePromptError.audioUnavailable
        let controller = makeController()

        controller.beginRecording()
        await settle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.errorMessage, VoicePromptError.audioUnavailable.localizedDescription)
    }

    func testSpeechRecognitionFailuresPreserveEditableDraft() async {
        let controller = makeController()
        controller.draft = "Existing prompt"
        controller.beginRecording()
        await settle()

        recognizer.emit(.failed("Audio input was interrupted."))
        await settle()

        XCTAssertEqual(controller.state, .editing)
        XCTAssertEqual(controller.draft, "Existing prompt")
        XCTAssertEqual(controller.errorMessage, "Audio input was interrupted.")
    }

    func testAutomaticRecordingTimeoutStopsAudioCapture() async throws {
        let controller = VoicePromptController(
            recognizer: recognizer,
            settings: settings,
            recordingTimeout: .milliseconds(20)
        )
        controller.beginRecording()
        await settle()
        recognizer.emit(.transcript("Short prompt", isFinal: false))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(controller.state, .editing)
        XCTAssertEqual(recognizer.stopCount, 1)
        XCTAssertEqual(controller.draft, "Short prompt")
    }

    func testRecognitionStripsHiddenTerminalControlCharacters() async {
        let controller = makeController()
        controller.beginRecording()
        await settle()

        recognizer.emit(.transcript("hello\u{1B}[31m\u{0}world", isFinal: false))
        await settle()

        XCTAssertEqual(controller.draft, "hello[31mworld")
        controller.cancelAndDiscard()
    }

    func testRecognitionLimitsOversizedUnicodeTranscriptsAtCharacterBoundaries() async {
        let controller = makeController()
        let veryLong = String(repeating: "界", count: VoicePromptSubmission.maximumPromptBytes)
        controller.beginRecording()
        await settle()

        recognizer.emit(.transcript(veryLong, isFinal: false))
        await settle()

        XCTAssertLessThanOrEqual(controller.draft.utf8.count, VoicePromptSubmission.maximumPromptBytes)
        XCTAssertTrue(controller.draft.allSatisfy { $0 == "界" })
        controller.cancelAndDiscard()
    }

    func testPrivacyCoordinatorClearsDraftWhenAppBackgroundsOrLocks() async {
        let coordinator = VoicePromptPrivacyCoordinator()
        let controller = makeController()
        controller.beginRecording()
        await settle()
        recognizer.emit(.transcript("Private customer credentials", isFinal: false))
        await settle()
        coordinator.activate(controller)

        coordinator.protectSensitiveContent()

        XCTAssertEqual(controller.draft, "")
        XCTAssertEqual(controller.lastTranscript, "")
        XCTAssertEqual(controller.state, .idle)
    }

    func testActivatingAnotherComposerErasesPreviousSessionDraft() {
        let coordinator = VoicePromptPrivacyCoordinator()
        let first = makeController()
        first.draft = "Private session one"
        let second = VoicePromptController(recognizer: MockVoicePromptRecognizer(), settings: settings)

        coordinator.activate(first)
        coordinator.activate(second)

        XCTAssertEqual(first.draft, "")
    }

    func testDeactivatingUnrelatedComposerCannotClearActiveDraft() {
        let coordinator = VoicePromptPrivacyCoordinator()
        let active = makeController()
        active.draft = "Keep me"
        let unrelated = VoicePromptController(recognizer: MockVoicePromptRecognizer(), settings: settings)
        coordinator.activate(active)

        coordinator.deactivate(unrelated)

        XCTAssertEqual(active.draft, "Keep me")
    }

    func testInsertSubmissionNeverAppendsReturnOrRequiresConfirmation() throws {
        let submission = try VoicePromptSubmission(draft: "Review the diff", action: .insert)

        XCTAssertEqual(submission.data, Data("Review the diff".utf8))
        XCTAssertFalse(submission.requiresConfirmation)
    }

    func testSubmitSubmissionAppendsReturnAndAlwaysRequiresConfirmation() throws {
        let submission = try VoicePromptSubmission(draft: "Run the checks", action: .submit)

        XCTAssertEqual(submission.data, Data("Run the checks\r".utf8))
        XCTAssertTrue(submission.requiresConfirmation)
        XCTAssertTrue(submission.confirmationMessage?.contains("Return") == true)
    }

    func testUnicodePromptIsSentAsUnmodifiedUTF8() throws {
        let prompt = "Revisar alteração ✅ — 日本語"
        let submission = try VoicePromptSubmission(draft: prompt, action: .insert)

        XCTAssertEqual(submission.text, prompt)
        XCTAssertEqual(submission.data, Data(prompt.utf8))
    }

    func testMultilineInsertionRequiresExplicitConfirmation() throws {
        let submission = try VoicePromptSubmission(draft: "first line\nsecond line", action: .insert)

        XCTAssertTrue(submission.requiresConfirmation)
        XCTAssertTrue(submission.confirmationMessage?.contains("Newlines") == true)
    }

    func testWindowsNewlinesAreNormalizedBeforeReview() throws {
        let submission = try VoicePromptSubmission(draft: "first\r\nsecond\rthird", action: .insert)

        XCTAssertEqual(submission.text, "first\nsecond\nthird")
        XCTAssertTrue(submission.requiresConfirmation)
    }

    func testLargePromptInsertionRequiresExplicitConfirmation() throws {
        let large = String(repeating: "x", count: TerminalPastePolicy.largePasteThreshold)
        let submission = try VoicePromptSubmission(draft: large, action: .insert)

        XCTAssertTrue(submission.requiresConfirmation)
        XCTAssertTrue(submission.confirmationMessage?.contains("bytes") == true)
    }

    func testOversizedPromptIsRejectedBeforeTerminalWrites() {
        let oversized = String(repeating: "x", count: VoicePromptSubmission.maximumPromptBytes + 1)

        XCTAssertThrowsError(try VoicePromptSubmission(draft: oversized, action: .insert)) { error in
            XCTAssertEqual(error as? VoicePromptError, .draftTooLarge(maximumBytes: VoicePromptSubmission.maximumPromptBytes))
        }
    }

    func testBlankPromptIsRejected() {
        XCTAssertThrowsError(try VoicePromptSubmission(draft: " \n ", action: .insert)) { error in
            XCTAssertEqual(error as? VoicePromptError, .emptyDraft)
        }
    }

    func testEscapeAndNulBytesAreRejectedBeforeTerminalWrites() {
        for character in ["\u{1B}", "\u{0}"] {
            XCTAssertThrowsError(try VoicePromptSubmission(draft: "unsafe\(character)prompt", action: .insert)) { error in
                XCTAssertEqual(error as? VoicePromptError, .unsafeControlCharacters)
            }
        }
    }

    func testDraftWhitespaceIsTrimmedWithoutAddingExecutionCharacters() throws {
        let submission = try VoicePromptSubmission(draft: "  inspect this patch\n ", action: .insert)

        XCTAssertEqual(submission.text, "inspect this patch")
        XCTAssertEqual(submission.data.last, UInt8(ascii: "h"))
    }

    func testRecordingCannotBeSubmittedUntilCaptureStops() async {
        let controller = makeController()
        controller.draft = "Existing draft"
        controller.beginRecording()
        await settle()

        XCTAssertFalse(controller.canSend)
        XCTAssertThrowsError(try controller.submission(action: .insert))

        controller.finishRecording()

        XCTAssertTrue(controller.canSend)
    }

    func testMicrophoneAndSpeechPrivacyDescriptionsArePresentInApplicationBundle() {
        let microphone = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        let speech = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String

        XCTAssertTrue(microphone?.localizedCaseInsensitiveContains("device") == true)
        XCTAssertTrue(speech?.localizedCaseInsensitiveContains("device") == true)
    }

    func testVoiceButtonIsAvailableAndEnabledInDefaultKeyboardToolbar() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: ToolbarButton.defaultButtons)

        XCTAssertTrue(ToolbarButton.defaultButtons.contains(.voicePrompt))
        XCTAssertTrue(ToolbarButton.allAvailable.contains(.voicePrompt))
        XCTAssertTrue(toolbar.voicePromptAvailable)
        XCTAssertEqual(ToolbarButton.voicePrompt.accessibilityLabel, "Compose on-device voice prompt")
    }

    func testPreviousDefaultToolbarMigratesToIncludeVoicePrompt() {
        let oldDefault = ToolbarButton.defaultButtons.filter { $0 != .voicePrompt }
        ToolbarConfigurationService.shared.saveButtons(oldDefault)

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), ToolbarButton.defaultButtons)
    }

    func testCustomizedToolbarWithoutVoicePromptIsPreserved() {
        ToolbarConfigurationService.shared.saveButtons([.ctrl, .paste])

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), [.ctrl, .paste])
    }

    func testMicrophoneToolbarActionOpensComposerWithoutSendingBytes() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .voicePrompt])
        var opened = 0
        var sent: [[UInt8]] = []
        toolbar.onVoicePrompt = { opened += 1 }
        toolbar.onButtonTap = { sent.append($0) }

        toolbar.handleButtonTap(.voicePrompt)

        XCTAssertEqual(opened, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testDisabledMicrophoneToolbarActionCannotOpenComposer() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.voicePrompt])
        var opened = false
        toolbar.onVoicePrompt = { opened = true }
        toolbar.setVoicePromptAvailable(false)

        toolbar.handleButtonTap(.voicePrompt)

        XCTAssertFalse(opened)
    }

    func testVoiceToolbarActionPreservesStickyModifiers() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .voicePrompt])
        toolbar.onVoicePrompt = {}

        toolbar.handleButtonTap(.ctrl)
        toolbar.handleButtonTap(.voicePrompt)

        XCTAssertEqual(toolbar.activeModifiers, ["ctrl"])
    }

    func testVoiceToolbarKeepsExistingKeyboardAccessoryHeight() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.voicePrompt])

        XCTAssertEqual(toolbar.intrinsicContentSize.height, KeyboardToolbarAccessoryView.preferredHeight)
        XCTAssertGreaterThanOrEqual(toolbar.intrinsicContentSize.height, 44)
    }

    func testTerminalSurfaceRoutesVoiceActionWithoutChangingKeyboardState() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: true)
        var opened = false
        surface.onVoicePrompt = { opened = true }

        surface.toolbarAccessory.handleButtonTap(.voicePrompt)

        XCTAssertTrue(opened)
        XCTAssertTrue(surface.isKeyboardVisible)
    }

    func testTerminalKeyboardVisibilityRestoresAfterVoiceComposition() {
        let visible = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: true)
        visible.setKeyboardVisible(false)
        visible.setKeyboardVisible(true)
        XCTAssertTrue(visible.isKeyboardVisible)

        let hidden = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        hidden.setKeyboardVisible(false)
        XCTAssertFalse(hidden.isKeyboardVisible)
    }

    private func makeController() -> VoicePromptController {
        VoicePromptController(recognizer: recognizer, settings: settings)
    }

    private func settle() async {
        for _ in 0..<12 {
            await Task.yield()
        }
    }
}

@MainActor
private final class MockVoicePromptRecognizer: VoicePromptRecognizing {
    var speechAuthorization: VoicePromptAuthorizationStatus = .authorized
    var microphoneAuthorization: VoicePromptAuthorizationStatus = .authorized
    var speechRequestResult: VoicePromptAuthorizationStatus = .authorized
    var microphoneRequestResult: VoicePromptAuthorizationStatus = .authorized
    var supportsOnDevice = true
    var recognizerAvailable = true
    var startError: (any Error)?
    var startCount = 0
    var stopCount = 0
    var cancelCount = 0
    var speechRequestCount = 0
    var microphoneRequestCount = 0
    var pauseMicrophoneAuthorization = false
    var startedLocale: String?
    var updateHandler: (@Sendable (VoicePromptRecognitionUpdate) -> Void)?
    private var microphoneContinuation: CheckedContinuation<VoicePromptAuthorizationStatus, Never>?

    func requestSpeechAuthorization() async -> VoicePromptAuthorizationStatus {
        speechRequestCount += 1
        speechAuthorization = speechRequestResult
        return speechAuthorization
    }

    func requestMicrophoneAuthorization() async -> VoicePromptAuthorizationStatus {
        microphoneRequestCount += 1
        if pauseMicrophoneAuthorization {
            return await withCheckedContinuation { continuation in
                microphoneContinuation = continuation
            }
        }
        microphoneAuthorization = microphoneRequestResult
        return microphoneAuthorization
    }

    func resumeMicrophoneAuthorization(with authorization: VoicePromptAuthorizationStatus) {
        microphoneAuthorization = authorization
        microphoneContinuation?.resume(returning: authorization)
        microphoneContinuation = nil
    }

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
        supportsOnDevice
    }

    func isAvailable(localeIdentifier: String) -> Bool {
        recognizerAvailable
    }

    func startRecognition(
        localeIdentifier: String,
        onUpdate: @escaping @Sendable (VoicePromptRecognitionUpdate) -> Void
    ) throws {
        startCount += 1
        startedLocale = localeIdentifier
        if let startError { throw startError }
        updateHandler = onUpdate
    }

    func stopRecognition() {
        stopCount += 1
        updateHandler = nil
    }

    func cancelRecognition() {
        cancelCount += 1
        updateHandler = nil
    }

    func emit(_ update: VoicePromptRecognitionUpdate) {
        updateHandler?(update)
    }
}
