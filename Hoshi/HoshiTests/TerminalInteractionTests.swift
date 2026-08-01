import GhosttyKit
import UIKit
import XCTest
@testable import Hoshi

@MainActor
final class TerminalInteractionTests: XCTestCase {
    private var savedToolbarButtons: [ToolbarButton] = []
    private var pasteboard: UIPasteboard!
    private var savedDoubleTapAction: TerminalDoubleTapAction = .selectWord
    private var savedTwoFingerTapAction: TerminalTwoFingerTapAction = .paste

    override func setUp() {
        super.setUp()
        savedToolbarButtons = ToolbarConfigurationService.shared.loadButtons()
        pasteboard = UIPasteboard.withUniqueName()
        TerminalPasteboard.shared = pasteboard
        savedDoubleTapAction = AppearanceSettings.shared.doubleTapAction
        savedTwoFingerTapAction = AppearanceSettings.shared.twoFingerTapAction
        ToolbarConfigurationService.shared.resetToDefaults()
        AppearanceSettings.shared.doubleTapAction = .selectWord
        AppearanceSettings.shared.twoFingerTapAction = .paste
    }

    override func tearDown() {
        ToolbarConfigurationService.shared.saveButtons(savedToolbarButtons)
        TerminalPasteboard.shared = .general
        UIPasteboard.remove(withName: pasteboard.name)
        pasteboard = nil
        AppearanceSettings.shared.doubleTapAction = savedDoubleTapAction
        AppearanceSettings.shared.twoFingerTapAction = savedTwoFingerTapAction
        super.tearDown()
    }

    func testTerminalClipboardTestsUsePrivateNamedPasteboard() {
        XCTAssertNotEqual(pasteboard.name, UIPasteboard.general.name)
        XCTAssertTrue(TerminalPasteboard.shared === pasteboard)
    }

    func testOrdinaryPasteDoesNotRequireConfirmation() {
        let assessment = TerminalPastePolicy.assess("echo hello", bracketedPasteEnabled: false)

        XCTAssertEqual(assessment.byteCount, 10)
        XCTAssertEqual(assessment.lineCount, 1)
        XCTAssertFalse(assessment.requiresConfirmation)
    }

    func testMultilinePasteRequiresConfirmationWithoutBracketedPaste() {
        let assessment = TerminalPastePolicy.assess("echo hello\nrm -rf danger", bracketedPasteEnabled: false)

        XCTAssertEqual(assessment.lineCount, 2)
        XCTAssertEqual(assessment.risks, [.multiline(lineCount: 2)])
        XCTAssertTrue(assessment.confirmationMessage.contains("Newlines"))
    }

    func testBracketedMultilinePasteDoesNotRequireConfirmation() {
        let assessment = TerminalPastePolicy.assess("echo hello\necho goodbye", bracketedPasteEnabled: true)

        XCTAssertEqual(assessment.lineCount, 2)
        XCTAssertFalse(assessment.requiresConfirmation)
    }

    func testWindowsNewlinesCountAsOneLineBreak() {
        let assessment = TerminalPastePolicy.assess("first\r\nsecond\r\nthird", bracketedPasteEnabled: false)

        XCTAssertEqual(assessment.lineCount, 3)
        XCTAssertEqual(assessment.risks, [.multiline(lineCount: 3)])
    }

    func testLargePasteRequiresConfirmationAtThreshold() {
        let safe = String(repeating: "a", count: TerminalPastePolicy.largePasteThreshold - 1)
        let large = String(repeating: "a", count: TerminalPastePolicy.largePasteThreshold)

        XCTAssertFalse(TerminalPastePolicy.assess(safe, bracketedPasteEnabled: true).requiresConfirmation)

        let assessment = TerminalPastePolicy.assess(large, bracketedPasteEnabled: true)
        XCTAssertEqual(assessment.risks, [.large(byteCount: TerminalPastePolicy.largePasteThreshold)])
        XCTAssertTrue(assessment.confirmationMessage.contains("bytes"))
    }

    func testBracketTerminatorAlwaysRequiresConfirmation() {
        let assessment = TerminalPastePolicy.assess("safe\u{1B}[201~unsafe", bracketedPasteEnabled: true)

        XCTAssertEqual(assessment.risks, [.bracketTerminator])
        XCTAssertTrue(assessment.confirmationMessage.contains("control sequence"))
    }

    func testEmptyPasteHasNoLinesOrRisk() {
        let assessment = TerminalPastePolicy.assess("", bracketedPasteEnabled: false)

        XCTAssertEqual(assessment.lineCount, 0)
        XCTAssertEqual(assessment.byteCount, 0)
        XCTAssertFalse(assessment.requiresConfirmation)
    }

    func testViewportSnapsToCompleteTerminalCells() throws {
        let geometry = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 390, height: 701),
            displayScale: 3,
            cellWidthPixels: 24,
            cellHeightPixels: 51
        ))

        XCTAssertEqual(geometry.widthPixels, 1_170)
        XCTAssertEqual(geometry.heightPixels, 2_103)
        XCTAssertEqual(geometry.columns, 48)
        XCTAssertEqual(geometry.rows, 41)
        XCTAssertEqual(geometry.snappedWidthPixels, 1_152)
        XCTAssertEqual(geometry.snappedHeightPixels, 2_091)
        XCTAssertEqual(geometry.snappedSize.height, 697)
    }

    func testKeyboardShowingReducesRowsAndHidingRestoresThem() throws {
        let expanded = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 390, height: 760),
            displayScale: 3,
            cellWidthPixels: 24,
            cellHeightPixels: 48
        ))
        let keyboardVisible = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 390, height: 408),
            displayScale: 3,
            cellWidthPixels: 24,
            cellHeightPixels: 48
        ))
        let restored = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 390, height: 760),
            displayScale: 3,
            cellWidthPixels: 24,
            cellHeightPixels: 48
        ))

        XCTAssertLessThan(keyboardVisible.rows, expanded.rows)
        XCTAssertEqual(restored.rows, expanded.rows)
        XCTAssertLessThanOrEqual(keyboardVisible.snappedHeightPixels, keyboardVisible.heightPixels)
        XCTAssertLessThanOrEqual(restored.snappedHeightPixels, restored.heightPixels)
    }

    func testViewportNeverRendersBeyondFractionalBounds() throws {
        let geometry = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 402.333, height: 287.666),
            displayScale: 3,
            cellWidthPixels: 19,
            cellHeightPixels: 43
        ))

        XCTAssertLessThanOrEqual(geometry.snappedWidthPixels, geometry.widthPixels)
        XCTAssertLessThanOrEqual(geometry.snappedHeightPixels, geometry.heightPixels)
        XCTAssertLessThanOrEqual(geometry.snappedSize.width, 402.333)
        XCTAssertLessThanOrEqual(geometry.snappedSize.height, 287.666)
    }

    func testRotationRecomputesColumnsAndRowsFromActualBounds() throws {
        let portrait = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 390, height: 760),
            displayScale: 3,
            cellWidthPixels: 24,
            cellHeightPixels: 48
        ))
        let landscape = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 760, height: 390),
            displayScale: 3,
            cellWidthPixels: 24,
            cellHeightPixels: 48
        ))

        XCTAssertGreaterThan(landscape.columns, portrait.columns)
        XCTAssertLessThan(landscape.rows, portrait.rows)
        XCTAssertLessThanOrEqual(landscape.snappedWidthPixels, landscape.widthPixels)
        XCTAssertLessThanOrEqual(landscape.snappedHeightPixels, landscape.heightPixels)
    }

    func testTinyViewportStaysWithinAvailablePixels() throws {
        let geometry = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 1, height: 1),
            displayScale: 2,
            cellWidthPixels: 25,
            cellHeightPixels: 50
        ))

        XCTAssertEqual(geometry.columns, 1)
        XCTAssertEqual(geometry.rows, 1)
        XCTAssertEqual(geometry.snappedWidthPixels, 2)
        XCTAssertEqual(geometry.snappedHeightPixels, 2)
    }

    func testViewportRejectsInvalidGeometry() {
        XCTAssertNil(TerminalViewportGeometry(
            bounds: CGSize(width: 0, height: 100),
            displayScale: 2,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))
        XCTAssertNil(TerminalViewportGeometry(
            bounds: CGSize(width: 100, height: 100),
            displayScale: 0,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))
        XCTAssertNil(TerminalViewportGeometry(
            bounds: CGSize(width: 100, height: 100),
            displayScale: 2,
            cellWidthPixels: 0,
            cellHeightPixels: 20
        ))
    }

    func testDockedKeyboardOverlapIsMeasured() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 700)
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 344)

        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(viewFrame: view, keyboardFrame: keyboard), 300)
    }

    func testHiddenFloatingAndOffscreenKeyboardsDoNotResizeTerminal() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 700)

        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(
            viewFrame: view,
            keyboardFrame: CGRect(x: 0, y: 844, width: 390, height: 344)
        ), 0)
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(
            viewFrame: view,
            keyboardFrame: CGRect(x: 60, y: 300, width: 250, height: 220)
        ), 0)
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(
            viewFrame: view,
            keyboardFrame: CGRect(x: 450, y: 500, width: 300, height: 300)
        ), 0)
    }

    func testDefaultToolbarContainsPaste() {
        XCTAssertTrue(ToolbarButton.defaultButtons.contains(.paste))
    }

    func testLegacyDefaultToolbarMigratesToIncludePaste() {
        let previousDefault = ToolbarButton.defaultButtons.filter { $0 != .paste }
        ToolbarConfigurationService.shared.saveButtons(previousDefault)

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), ToolbarButton.defaultButtons)
    }

    func testCustomizedToolbarWithoutPasteIsPreserved() {
        ToolbarConfigurationService.shared.saveButtons([.ctrl, .arrowUp])

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), [.ctrl, .arrowUp])
    }

    func testSelectionAddsCopyImmediatelyBeforePaste() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .paste])

        XCTAssertEqual(toolbar.displayedButtons, [.ctrl, .paste])

        toolbar.setSelectionAvailable(true)

        XCTAssertEqual(toolbar.displayedButtons, [.ctrl, .copy, .paste])

        toolbar.setSelectionAvailable(false)

        XCTAssertEqual(toolbar.displayedButtons, [.ctrl, .paste])
    }

    func testExplicitCopyButtonIsNotDuplicated() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.copy, .paste])
        toolbar.setSelectionAvailable(true)

        XCTAssertEqual(toolbar.displayedButtons.filter { $0.id == ToolbarButton.copy.id }.count, 1)
    }

    func testUnavailableClipboardActionsDoNothing() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.copy, .paste])
        var actions: [ClipboardAction] = []
        toolbar.onClipboardAction = { actions.append($0) }
        toolbar.setPasteAvailable(false)

        toolbar.handleButtonTap(.copy)
        toolbar.handleButtonTap(.paste)

        XCTAssertTrue(actions.isEmpty)
    }

    func testAvailableClipboardActionsReachTerminal() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.copy, .paste])
        var actions: [ClipboardAction] = []
        toolbar.onClipboardAction = { actions.append($0) }
        toolbar.setSelectionAvailable(true)
        toolbar.setPasteAvailable(true)

        toolbar.handleButtonTap(.copy)
        toolbar.handleButtonTap(.paste)

        XCTAssertEqual(actions, [.copy, .paste])
    }

    func testModifierSurvivesToolbarRefreshAndAppliesToNextKey() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: ToolbarButton.defaultButtons)
        var sent: [[UInt8]] = []
        toolbar.onButtonTap = { sent.append($0) }

        toolbar.handleButtonTap(.ctrl)
        toolbar.reloadButtons()

        XCTAssertEqual(toolbar.activeModifiers, ["ctrl"])

        let letterA = ToolbarButton(id: "letter-a", label: "a", bytes: [0x61], category: .symbol)
        toolbar.handleButtonTap(letterA)

        XCTAssertEqual(sent, [[0x01]])
        XCTAssertTrue(toolbar.activeModifiers.isEmpty)
    }

    func testModifierSurvivesChangedToolbarLayoutWhenStillPresent() {
        ToolbarConfigurationService.shared.saveButtons([.ctrl, .paste])
        let toolbar = KeyboardToolbarAccessoryView()
        toolbar.handleButtonTap(.ctrl)

        ToolbarConfigurationService.shared.saveButtons([.ctrl, .arrowUp, .paste])
        toolbar.reloadButtons()

        XCTAssertEqual(toolbar.activeModifiers, ["ctrl"])
    }

    func testRemovedModifierDoesNotSurviveToolbarCustomization() {
        ToolbarConfigurationService.shared.saveButtons([.ctrl, .paste])
        let toolbar = KeyboardToolbarAccessoryView()
        toolbar.handleButtonTap(.ctrl)

        ToolbarConfigurationService.shared.saveButtons([.arrowUp, .paste])
        toolbar.reloadButtons()

        XCTAssertTrue(toolbar.activeModifiers.isEmpty)
    }

    func testMultipleModifiersEncodeTerminalArrowSequence() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .shift, .arrowUp])
        var sent: [[UInt8]] = []
        toolbar.onButtonTap = { sent.append($0) }

        toolbar.handleButtonTap(.ctrl)
        toolbar.handleButtonTap(.shift)
        toolbar.handleButtonTap(.arrowUp)

        XCTAssertEqual(sent, [[0x1B, 0x5B, 0x31, 0x3B, 0x36, 0x41]])
        XCTAssertTrue(toolbar.activeModifiers.isEmpty)
    }

    func testToolbarMeetsMinimumTouchHeightAndAccessibleLabels() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: ToolbarButton.defaultButtons)

        XCTAssertGreaterThanOrEqual(toolbar.intrinsicContentSize.height, 44)
        XCTAssertEqual(ToolbarButton.arrowUp.accessibilityLabel, "Up arrow")
        XCTAssertEqual(ToolbarButton.ctrlB.accessibilityLabel, "Control B, tmux prefix")
    }

    func testTerminalSurfaceExposesCopyPasteAndSelectionGestures() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        let taps = surface.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []

        XCTAssertTrue(taps.contains { $0.numberOfTapsRequired == 2 && $0.numberOfTouchesRequired == 1 })
        XCTAssertTrue(taps.contains { $0.numberOfTouchesRequired == 2 })
        XCTAssertTrue(surface.interactions.contains { $0 is UIEditMenuInteraction })
        XCTAssertFalse(surface.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))

        pasteboard.string = "paste me"

        XCTAssertTrue(surface.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    }

    func testKeyboardVisibilityCanBeHiddenAndRestored() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: true)

        surface.setKeyboardVisible(false)
        XCTAssertFalse(surface.isKeyboardVisible)

        surface.setKeyboardVisible(true)
        XCTAssertTrue(surface.isKeyboardVisible)
    }

    func testSoftwareKeyboardInputUsesTerminalNewlinesAndStickyModifiers() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        surface.insertText("hello\n")
        surface.toolbarAccessory.handleButtonTap(.ctrl)
        surface.insertText("a")
        surface.deleteBackward()

        XCTAssertEqual(sent, [Data("hello\r".utf8), Data([0x01]), Data([0x7F])])
    }

    func testGestureDefaultsSupportSelectionAndTwoFingerPaste() {
        XCTAssertEqual(AppearanceSettings.shared.doubleTapAction, .selectWord)
        XCTAssertEqual(AppearanceSettings.shared.twoFingerTapAction, .paste)
    }

    func testDisabledGestureDoesNotPasteClipboard() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "echo first\necho second"
        AppearanceSettings.shared.doubleTapAction = .disabled
        AppearanceSettings.shared.twoFingerTapAction = .disabled
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.performDoubleTapAction(at: CGPoint(x: 40, y: 40))
        surface.performTwoFingerTapAction(at: CGPoint(x: 40, y: 40))

        XCTAssertNil(request)
    }

    func testDoubleTapCanBeConfiguredToPaste() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "echo first\necho second"
        AppearanceSettings.shared.doubleTapAction = .paste
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.performDoubleTapAction(at: CGPoint(x: 40, y: 40))

        XCTAssertEqual(request?.kind, .paste)
    }

    func testRemoteClipboardWriteRequiresApproval() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        pasteboard.string = "original"
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.requestRemoteClipboardWrite("remote replacement")

        XCTAssertEqual(request?.kind, .remoteWrite)
        XCTAssertEqual(pasteboard.string, "original")

        request?.onDecision(false)

        XCTAssertEqual(pasteboard.string, "original")

        surface.requestRemoteClipboardWrite("approved replacement")
        request?.onDecision(true)

        XCTAssertEqual(pasteboard.string, "approved replacement")
    }

    func testLiveGhosttySurfaceResizesWhenKeyboardAppearsAndDisappears() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 760))
        let expanded = ghostty_surface_size(try XCTUnwrap(surface.surface))

        surface.frame.size.height = 408
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        let compressed = ghostty_surface_size(try XCTUnwrap(surface.surface))

        surface.frame.size.height = 760
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        let restored = ghostty_surface_size(try XCTUnwrap(surface.surface))

        XCTAssertGreaterThan(expanded.rows, 0)
        XCTAssertLessThan(compressed.rows, expanded.rows)
        XCTAssertEqual(restored.rows, expanded.rows)
    }

    func testLiveGhosttySurfaceSelectsAndCopiesRemoteOutput() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("hello from the remote terminal".utf8))

        surface.selectAll(nil)

        XCTAssertTrue(surface.hasSelection())
        XCTAssertTrue(surface.readSelection()?.contains("hello from the remote terminal") == true)
        XCTAssertTrue(surface.copyToClipboard())
        XCTAssertTrue(pasteboard.string?.contains("hello from the remote terminal") == true)
        XCTAssertTrue(surface.toolbarAccessory.selectionAvailable)
        XCTAssertTrue(surface.toolbarAccessory.displayedButtons.contains(.copy))
    }

    func testLiveWordSelectionBypassesApplicationMouseCapture() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("\u{1B}[?1002hhello selected word".utf8))
        let handle = try XCTUnwrap(surface.surface)

        XCTAssertTrue(ghostty_surface_mouse_captured(handle))

        surface.performDoubleTapAction(at: CGPoint(x: 14, y: 8))

        XCTAssertTrue(surface.hasSelection())
        XCTAssertFalse(surface.readSelection()?.isEmpty ?? true)
    }

    func testUnsafeLivePasteRequiresApprovalAndCancellationSendsNothing() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "echo first\necho second"
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }

        surface.pasteFromClipboard()

        XCTAssertEqual(request?.kind, .paste)
        XCTAssertEqual(request?.assessment.risks, [.multiline(lineCount: 2)])
        XCTAssertTrue(sent.isEmpty)

        request?.onDecision(false)

        XCTAssertTrue(sent.isEmpty)
    }

    func testApprovedLiveMultilinePasteSendsEncodedTerminalInput() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "echo first\necho second"
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }

        surface.pasteFromClipboard()
        request?.onDecision(true)
        await waitUntil { !sent.isEmpty }

        XCTAssertEqual(String(data: sent.reduce(Data(), +), encoding: .utf8), "echo first\recho second")
    }

    func testBracketedLivePastePreservesMultilineDataWithoutPrompt() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("\u{1B}[?2004h".utf8))
        pasteboard.string = "echo first\necho second"
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }

        surface.pasteFromClipboard()
        await waitUntil { !sent.isEmpty }

        XCTAssertNil(request)
        XCTAssertEqual(
            String(data: sent.reduce(Data(), +), encoding: .utf8),
            "\u{1B}[200~echo first\necho second\u{1B}[201~"
        )
    }

    func testLiveOSC52CopiesRemoteTextIntoDeviceClipboard() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        let payload = Data("copied through OSC52".utf8).base64EncodedString()

        surface.writeRemoteOutput(Array("\u{1B}]52;c;\(payload)\u{07}".utf8))
        await waitUntil { self.pasteboard.string == "copied through OSC52" }

        XCTAssertEqual(pasteboard.string, "copied through OSC52")
    }

    func testLiveOSC52WriteHonorsGhosttyConfirmationPolicy() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        let handle = try XCTUnwrap(surface.surface)
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        let configText = "clipboard-write = ask"
        configText.withCString { text in
            ghostty_config_load_string(config, text, UInt(configText.utf8.count))
        }
        ghostty_config_finalize(config)
        ghostty_surface_update_config(handle, config)

        pasteboard.string = "existing clipboard"
        let payload = Data("approved remote clipboard".utf8).base64EncodedString()
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;\(payload)\u{07}".utf8))
        await waitUntil { request != nil }

        XCTAssertEqual(request?.kind, .remoteWrite)
        XCTAssertEqual(pasteboard.string, "existing clipboard")

        request?.onDecision(true)

        XCTAssertEqual(pasteboard.string, "approved remote clipboard")
    }

    func testLiveOSC52ClipboardReadRequiresApproval() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "private clipboard"
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;?\u{07}".utf8))
        await waitUntil { request != nil }

        XCTAssertEqual(request?.kind, .remoteRead)
        XCTAssertTrue(sent.isEmpty)

        request?.onDecision(true)
        await waitUntil { !sent.isEmpty }

        let response = String(data: sent.reduce(Data(), +), encoding: .utf8)
        XCTAssertTrue(response?.contains(Data("private clipboard".utf8).base64EncodedString()) == true)
    }

    private func makeLiveSurface(size: CGSize) throws -> GhosttyTerminalSurfaceView {
        let app = try XCTUnwrap(GhosttyRuntimeController.shared.app)
        let surface = GhosttyTerminalSurfaceView(app: app, fontSize: 14, keyboardVisible: false)
        surface.frame = CGRect(origin: .zero, size: size)
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        XCTAssertNotNil(surface.surface)
        return surface
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            GhosttyRuntimeController.shared.tick()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
