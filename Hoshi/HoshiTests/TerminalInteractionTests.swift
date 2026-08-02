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

    func testConnectionStatesExposeCompactLabelsAndAvailability() {
        XCTAssertEqual(ConnectionState.sshBootstrap.conciseLabel, "Starting SSH")
        XCTAssertEqual(ConnectionState.moshStarting.conciseLabel, "Starting Mosh")
        XCTAssertEqual(ConnectionState.error("failed").conciseLabel, "Connection Error")
        XCTAssertTrue(ConnectionState.reconnecting.isTransient)
        XCTAssertFalse(ConnectionState.connected.isTransient)
        XCTAssertTrue(ConnectionState.disconnected.isUnavailable)
        XCTAssertTrue(ConnectionState.error("failed").isUnavailable)
        XCTAssertFalse(ConnectionState.reconnecting.isUnavailable)
    }

    func testTerminalHeaderPullDistinguishesPickerFromMinimize() {
        XCTAssertEqual(
            TerminalHeaderPullAction.resolve(translation: CGSize(width: 2, height: 48)),
            .showSessions
        )
        XCTAssertEqual(
            TerminalHeaderPullAction.resolve(translation: CGSize(width: 4, height: 120)),
            .minimize
        )
    }

    func testTerminalHeaderPullIgnoresHorizontalAndShortGestures() {
        XCTAssertEqual(
            TerminalHeaderPullAction.resolve(translation: CGSize(width: 50, height: 35)),
            .none
        )
        XCTAssertEqual(
            TerminalHeaderPullAction.resolve(translation: CGSize(width: 0, height: 20)),
            .none
        )
        XCTAssertEqual(
            TerminalHeaderPullAction.resolve(translation: CGSize(width: 0, height: -120)),
            .none
        )
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

    func testRemoteClipboardDefaultsRequireApprovalForReadsAndWrites() {
        let policy = TerminalRemoteClipboardPolicy()

        XCTAssertEqual(policy.read, .ask)
        XCTAssertEqual(policy.write, .ask)
    }

    func testRemoteClipboardPolicyUsesTheActiveServerProfile() {
        let server = Server(
            name: "Production",
            hostname: "example.com",
            port: 2222,
            username: "deploy",
            remoteClipboardReadPolicy: .deny,
            remoteClipboardWritePolicy: .allow
        )

        let policy = TerminalRemoteClipboardPolicy.forServer(server)

        XCTAssertEqual(policy.read, .deny)
        XCTAssertEqual(policy.write, .allow)
        XCTAssertEqual(policy.serverName, "Production")
        XCTAssertEqual(policy.endpoint, "example.com:2222")
    }

    func testClipboardCStringDecoderAcceptsPayloadAtSizeLimit() {
        let content = String(repeating: "a", count: TerminalClipboardPayload.maximumBytes)

        let result = content.withCString { TerminalClipboardPayload.decodeCString($0) }

        XCTAssertEqual(try? result.get(), content)
    }

    func testClipboardCStringDecoderBoundsOversizedRemotePayload() {
        let content = String(repeating: "a", count: TerminalClipboardPayload.maximumBytes + 256)

        let result = content.withCString { TerminalClipboardPayload.decodeCString($0) }

        guard case .failure(.tooLarge(let byteCount)) = result else {
            return XCTFail("Expected oversized clipboard payload to be rejected")
        }
        XCTAssertEqual(byteCount, TerminalClipboardPayload.maximumBytes + 1)
    }

    func testClipboardCStringDecoderRejectsInvalidUTF8() {
        let bytes: [UInt8] = [0xC3, 0x28, 0]

        let result = bytes.withUnsafeBufferPointer { buffer in
            TerminalClipboardPayload.decodeCString(
                UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
            )
        }

        XCTAssertEqual(result, .failure(.invalidUTF8))
    }

    func testRemoteClipboardSizeLimitCountsUTF8BytesRatherThanCharacters() {
        let oversized = String(repeating: "🛡️", count: TerminalClipboardPayload.maximumBytes / 4)

        XCTAssertLessThan(oversized.count, TerminalClipboardPayload.maximumBytes)
        guard case .failure(.tooLarge(let byteCount)) = TerminalClipboardPayload.validate(oversized) else {
            return XCTFail("Expected UTF-8 clipboard byte limit to be enforced")
        }
        XCTAssertGreaterThan(byteCount, TerminalClipboardPayload.maximumBytes)
    }

    func testRemoteClipboardApprovalMessagesHidePrivateContents() {
        let secret = "private-token-never-display"
        let assessment = TerminalPastePolicy.assess(secret, bracketedPasteEnabled: false)
        let read = TerminalClipboardRequest(
            content: secret,
            kind: .remoteRead,
            assessment: assessment,
            serverName: "Production",
            endpoint: "example.com:2222"
        ) { _ in }
        let write = TerminalClipboardRequest(
            content: secret,
            kind: .remoteWrite,
            assessment: assessment,
            serverName: "Production",
            endpoint: "example.com:2222"
        ) { _ in }

        XCTAssertTrue(read.message.contains("example.com:2222"))
        XCTAssertTrue(write.message.contains("example.com:2222"))
        XCTAssertTrue(read.message.contains("\(secret.utf8.count) bytes"))
        XCTAssertTrue(write.message.contains("\(secret.utf8.count) bytes"))
        XCTAssertFalse(read.message.contains(secret))
        XCTAssertFalse(write.message.contains(secret))
    }

    func testGhosttyConfigurationAlwaysRequiresRemoteReadAuthorization() {
        let configuration = GhosttyThemeAdapter.buildConfigString(from: AppearanceSettings.shared)

        XCTAssertTrue(configuration.contains("clipboard-read = ask"))
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
        XCTAssertEqual(geometry.centeredOrigin, CGPoint(x: 3, y: 2))
        XCTAssertEqual(geometry.centeredFrame, CGRect(x: 3, y: 2, width: 384, height: 697))
        XCTAssertEqual(geometry.snappedSize.height, 697)
    }

    func testViewportBalancesRemainderAroundCenteredGridAtPixelBoundaries() throws {
        let geometry = try XCTUnwrap(TerminalViewportGeometry(
            bounds: CGSize(width: 100, height: 100),
            displayScale: 3,
            cellWidthPixels: 29,
            cellHeightPixels: 43
        ))

        let leftPixels = Int((geometry.centeredFrame.minX * geometry.displayScale).rounded())
        let topPixels = Int((geometry.centeredFrame.minY * geometry.displayScale).rounded())
        let rightPixels = geometry.widthPixels - geometry.snappedWidthPixels - leftPixels
        let bottomPixels = geometry.heightPixels - geometry.snappedHeightPixels - topPixels

        XCTAssertLessThanOrEqual(abs(leftPixels - rightPixels), 1)
        XCTAssertLessThanOrEqual(abs(topPixels - bottomPixels), 1)
        XCTAssertEqual(geometry.centeredFrame.size, geometry.snappedSize)
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

    func testOnlyActiveKeyboardDismissalsChangeTheUserPreference() {
        XCTAssertTrue(TerminalApplicationLifecycle.shouldRecordKeyboardDismissal(
            applicationState: .active
        ))
        XCTAssertFalse(TerminalApplicationLifecycle.shouldRecordKeyboardDismissal(
            applicationState: .inactive
        ))
        XCTAssertFalse(TerminalApplicationLifecycle.shouldRecordKeyboardDismissal(
            applicationState: .background
        ))
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

    func testSelectionAddsCopyAtFrontOfToolbar() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .paste])

        XCTAssertEqual(toolbar.displayedButtons, [.ctrl, .paste])

        toolbar.setSelectionAvailable(true)

        XCTAssertEqual(toolbar.displayedButtons, [.copy, .ctrl, .paste])

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

    func testToolbarUsesCompactHeightWithMinimumTouchTargetsAndAccessibleLabels() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: ToolbarButton.defaultButtons)

        XCTAssertEqual(toolbar.intrinsicContentSize.height, 44)
        XCTAssertEqual(KeyboardToolbarAccessoryView.buttonVisualHeight, 36)
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

    func testTerminalCanRestoreInputFocusAfterAnInteractionTakesIt() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: true)
        controller.view = surface
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        XCTAssertTrue(surface.restoreInputFocus())
        XCTAssertTrue(surface.isFirstResponder)
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

    func testRemoteClipboardWriteFailsClosedWhenApprovalCannotBePresented() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        pasteboard.string = "existing clipboard"
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardNotice = { notices.append($0) }

        surface.requestRemoteClipboardWrite("unapproved replacement")

        XCTAssertEqual(pasteboard.string, "existing clipboard")
        XCTAssertEqual(notices.map(\.kind), [.writeDenied])
    }

    func testDeniedRemoteClipboardWriteNeverChangesPasteboard() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .deny, serverName: "Production")
        pasteboard.string = "existing private clipboard"
        var requests: [TerminalClipboardRequest] = []
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardRequest = { requests.append($0) }
        surface.onClipboardNotice = { notices.append($0) }

        surface.requestRemoteClipboardWrite("remote secret")

        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(pasteboard.string, "existing private clipboard")
        XCTAssertEqual(notices.map(\.kind), [.writeDenied])
        XCTAssertFalse(notices[0].message.contains("remote secret"))
    }

    func testAllowedRemoteClipboardWriteUpdatesPasteboardWithoutPrompt() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .allow, serverName: "Production")
        var request: TerminalClipboardRequest?
        var notice: TerminalClipboardNotice?
        surface.onClipboardRequest = { request = $0 }
        surface.onClipboardNotice = { notice = $0 }

        surface.requestRemoteClipboardWrite("remote secret")

        XCTAssertNil(request)
        XCTAssertEqual(pasteboard.string, "remote secret")
        XCTAssertEqual(notice?.kind, .writeAllowed)
        XCTAssertTrue(notice?.message.contains("Production") == true)
        XCTAssertFalse(notice?.message.contains("remote secret") == true)
    }

    func testGhosttyConfirmationStillRequiresApprovalOnTrustedProfile() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .allow)
        pasteboard.string = "original"
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.requestRemoteClipboardWrite("replacement", requiresConfirmation: true)

        XCTAssertEqual(request?.kind, .remoteWrite)
        XCTAssertEqual(pasteboard.string, "original")
    }

    func testOversizedRemoteClipboardWriteIsRejectedBeforeChangingPasteboard() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .allow)
        pasteboard.string = "existing clipboard"
        let oversized = String(repeating: "a", count: TerminalClipboardPayload.maximumBytes + 1)
        var request: TerminalClipboardRequest?
        var notice: TerminalClipboardNotice?
        surface.onClipboardRequest = { request = $0 }
        surface.onClipboardNotice = { notice = $0 }

        surface.requestRemoteClipboardWrite(oversized)

        XCTAssertNil(request)
        XCTAssertEqual(pasteboard.string, "existing clipboard")
        XCTAssertEqual(notice?.kind, .payloadTooLarge)
        XCTAssertEqual(notice?.byteCount, oversized.utf8.count)
    }

    func testClipboardApprovalDecisionCannotBeAppliedTwice() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        var request: TerminalClipboardRequest?
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onClipboardNotice = { notices.append($0) }

        surface.requestRemoteClipboardWrite("approved once")
        request?.onDecision(true)
        request?.onDecision(false)

        XCTAssertEqual(pasteboard.string, "approved once")
        XCTAssertEqual(notices.map(\.kind), [.writeAllowed])
    }

    func testCancellingPendingClipboardRequestsFailsClosed() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        pasteboard.string = "original"
        var requests: [TerminalClipboardRequest] = []
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardRequest = { requests.append($0) }
        surface.onClipboardNotice = { notices.append($0) }

        surface.requestRemoteClipboardWrite("first secret")
        surface.requestRemoteClipboardWrite("second secret")
        surface.cancelPendingClipboardRequests()
        requests.forEach { $0.onDecision(true) }

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(pasteboard.string, "original")
        XCTAssertEqual(notices.map(\.kind), [.writeDenied, .writeDenied])
        XCTAssertTrue(notices.allSatisfy { !$0.message.contains("secret") })
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

    func testTypingClearsLiveSelectionAndRestoresToolbarState() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("selected terminal output".utf8))
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        surface.selectAll(nil)
        XCTAssertTrue(surface.hasSelection())
        XCTAssertTrue(surface.toolbarAccessory.selectionAvailable)

        surface.insertText("x")

        XCTAssertFalse(surface.hasSelection())
        XCTAssertFalse(surface.toolbarAccessory.selectionAvailable)
        XCTAssertEqual(sent, [Data("x".utf8)])
    }

    func testDeniedRemoteClipboardPoliciesDoNotBlockIntentionalLocalCopy() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(read: .deny, write: .deny)
        surface.writeRemoteOutput(Array("local selection stays available".utf8))

        surface.selectAll(nil)

        XCTAssertTrue(surface.copyToClipboard())
        XCTAssertTrue(pasteboard.string?.contains("local selection stays available") == true)
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

    func testDeniedRemoteClipboardPoliciesDoNotBlockIntentionalLocalPaste() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(read: .deny, write: .deny)
        pasteboard.string = "echo intentional local paste"
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        surface.pasteFromClipboard()
        await waitUntil { !sent.isEmpty }

        XCTAssertEqual(
            String(data: sent.reduce(Data(), +), encoding: .utf8),
            "echo intentional local paste"
        )
    }

    func testLiveOSC52CopiesRemoteTextIntoDeviceClipboard() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .allow)
        let payload = Data("copied through OSC52".utf8).base64EncodedString()

        surface.writeRemoteOutput(Array("\u{1B}]52;c;\(payload)\u{07}".utf8))
        await waitUntil { self.pasteboard.string == "copied through OSC52" }

        XCTAssertEqual(pasteboard.string, "copied through OSC52")
    }

    func testLiveOSC52WriteRequiresApprovalByDefault() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "private existing clipboard"
        let payload = Data("remote replacement".utf8).base64EncodedString()
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;\(payload)\u{07}".utf8))
        await waitUntil { request != nil }

        XCTAssertEqual(request?.kind, .remoteWrite)
        XCTAssertEqual(pasteboard.string, "private existing clipboard")

        request?.onDecision(true)

        XCTAssertEqual(pasteboard.string, "remote replacement")
    }

    func testLiveFragmentedOSC52WritePreservesApprovalBoundary() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        pasteboard.string = "existing clipboard"
        let payload = Data("fragmented remote content".utf8).base64EncodedString()
        var request: TerminalClipboardRequest?
        surface.onClipboardRequest = { request = $0 }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;".utf8))
        GhosttyRuntimeController.shared.tick()
        XCTAssertNil(request)
        surface.writeRemoteOutput(Array("\(payload)\u{1B}\\".utf8))
        await waitUntil { request != nil }

        XCTAssertEqual(request?.kind, .remoteWrite)
        XCTAssertEqual(pasteboard.string, "existing clipboard")

        request?.onDecision(true)

        XCTAssertEqual(pasteboard.string, "fragmented remote content")
    }

    func testLiveOSC52WriteHonorsDeniedServerPolicy() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .deny, serverName: "Production")
        pasteboard.string = "private existing clipboard"
        let payload = Data("remote replacement".utf8).base64EncodedString()
        var request: TerminalClipboardRequest?
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onClipboardNotice = { notices.append($0) }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;\(payload)\u{07}".utf8))
        await waitUntil { !notices.isEmpty }

        XCTAssertNil(request)
        XCTAssertEqual(pasteboard.string, "private existing clipboard")
        XCTAssertEqual(notices.map(\.kind), [.writeDenied])
    }

    func testLiveOversizedOSC52WriteNeverChangesPasteboard() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(write: .allow)
        pasteboard.string = "private existing clipboard"
        let oversized = String(repeating: "a", count: TerminalClipboardPayload.maximumBytes + 1)
        let payload = Data(oversized.utf8).base64EncodedString()
        var request: TerminalClipboardRequest?
        var notice: TerminalClipboardNotice?
        surface.onClipboardRequest = { request = $0 }
        surface.onClipboardNotice = { notice = $0 }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;\(payload)\u{07}".utf8))
        await waitUntil(timeout: 2) { notice != nil }

        XCTAssertNil(request)
        XCTAssertEqual(pasteboard.string, "private existing clipboard")
        XCTAssertEqual(notice?.kind, .payloadTooLarge)
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

    func testLiveOSC52ClipboardReadHonorsTrustedServerPolicy() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(read: .allow, serverName: "Production")
        pasteboard.string = "private clipboard"
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }
        surface.onClipboardNotice = { notices.append($0) }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;?\u{07}".utf8))
        await waitUntil { !sent.isEmpty }

        XCTAssertNil(request)
        let response = String(data: sent.reduce(Data(), +), encoding: .utf8)
        XCTAssertTrue(response?.contains(Data("private clipboard".utf8).base64EncodedString()) == true)
        XCTAssertEqual(notices.map(\.kind), [.readAllowed])
    }

    func testLiveOSC52ClipboardReadDenialNeverExposesPrivateContents() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(read: .deny, serverName: "Production")
        let secret = "private-token-never-send"
        pasteboard.string = secret
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        var notices: [TerminalClipboardNotice] = []
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }
        surface.onClipboardNotice = { notices.append($0) }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;?\u{07}".utf8))
        await waitUntil { !notices.isEmpty }

        XCTAssertNil(request)
        XCTAssertEqual(notices.map(\.kind), [.readDenied])
        let response = String(data: sent.reduce(Data(), +), encoding: .utf8) ?? ""
        XCTAssertFalse(response.contains(Data(secret.utf8).base64EncodedString()))
        XCTAssertFalse(notices[0].message.contains(secret))
    }

    func testLiveOSC52ClipboardReadRejectsOversizedPasteboard() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.clipboardPolicy = TerminalRemoteClipboardPolicy(read: .allow)
        pasteboard.string = String(repeating: "a", count: TerminalClipboardPayload.maximumBytes + 1)
        var request: TerminalClipboardRequest?
        var sent: [Data] = []
        var notice: TerminalClipboardNotice?
        surface.onClipboardRequest = { request = $0 }
        surface.onInputData = { sent.append($0) }
        surface.onClipboardNotice = { notice = $0 }

        surface.writeRemoteOutput(Array("\u{1B}]52;c;?\u{07}".utf8))
        await waitUntil { notice != nil }

        XCTAssertNil(request)
        XCTAssertEqual(notice?.kind, .payloadTooLarge)
        let response = String(data: sent.reduce(Data(), +), encoding: .utf8) ?? ""
        XCTAssertLessThan(response.utf8.count, 64)
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
