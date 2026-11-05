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

    // MARK: - Arrow joystick

    func testArrowJoystickIgnoresDeadZoneAndFillsTowardThreshold() {
        var joystick = TerminalArrowJoystick()
        XCTAssertEqual(joystick.update(translation: CGPoint(x: 5, y: 3)), .idle)

        let half = joystick.update(translation: CGPoint(x: 18, y: 2))
        XCTAssertEqual(half.direction, .right)
        XCTAssertEqual(half.fill, 0.5, accuracy: 0.001)
        XCTAssertEqual(half.gear, 0)

        let armed = joystick.update(translation: CGPoint(x: 0, y: -40))
        XCTAssertEqual(armed.direction, .up)
        XCTAssertEqual(armed.fill, 1)
        XCTAssertEqual(armed.gear, 1)
    }

    func testArrowJoystickGearsRiseWithDistancePastThreshold() {
        var joystick = TerminalArrowJoystick()
        XCTAssertEqual(joystick.update(translation: CGPoint(x: -36 - 39, y: 0)).gear, 1)
        XCTAssertEqual(joystick.update(translation: CGPoint(x: -36 - 40, y: 0)).gear, 2)
        XCTAssertEqual(joystick.update(translation: CGPoint(x: -36 - 90, y: 0)).gear, 3)
        XCTAssertEqual(joystick.state.direction, .left)
        XCTAssertLessThan(TerminalArrowJoystick.repeatInterval(gear: 3), TerminalArrowJoystick.repeatInterval(gear: 1))
    }

    func testArrowJoystickNeedsAClearLeadToSwitchAxes() {
        var joystick = TerminalArrowJoystick()
        _ = joystick.update(translation: CGPoint(x: 40, y: 0))
        // A near-diagonal drag keeps the current axis...
        XCTAssertEqual(joystick.update(translation: CGPoint(x: 40, y: 48)).direction, .right)
        // ...until the other axis clearly leads.
        XCTAssertEqual(joystick.update(translation: CGPoint(x: 40, y: 60)).direction, .down)
    }

    func testArrowJoystickReleaseSelectsTextOnlyWhenTheHoldNeverDragged() {
        var joystick = TerminalArrowJoystick()
        XCTAssertTrue(joystick.releaseSelectsText)

        // Finger jitter inside the dead zone is still a stationary hold.
        _ = joystick.update(translation: CGPoint(x: 4, y: -5))
        XCTAssertTrue(joystick.releaseSelectsText)

        // Dragging out and back is steering, not selecting.
        _ = joystick.update(translation: CGPoint(x: 20, y: 0))
        _ = joystick.update(translation: .zero)
        XCTAssertFalse(joystick.releaseSelectsText)

        joystick.reset()
        XCTAssertTrue(joystick.releaseSelectsText)
    }

    func testArrowRepeaterFiresOnceThenRepeatsAfterDelay() {
        var repeater = TerminalArrowRepeater()
        let armed = TerminalArrowJoystick.State(direction: .right, fill: 1, gear: 1)

        XCTAssertEqual(repeater.advance(armed, now: 0), .right)
        XCTAssertNil(repeater.advance(armed, now: 0.2))
        XCTAssertEqual(repeater.advance(armed, now: 0.36), .right)
        XCTAssertNil(repeater.advance(armed, now: 0.40))
        XCTAssertEqual(repeater.advance(armed, now: 0.52), .right)

        // Dropping below the threshold stops; re-arming fires immediately.
        XCTAssertNil(repeater.advance(.idle, now: 0.6))
        XCTAssertEqual(repeater.advance(armed, now: 0.61), .right)

        // A new direction fires right away.
        let down = TerminalArrowJoystick.State(direction: .down, fill: 1, gear: 1)
        XCTAssertEqual(repeater.advance(down, now: 0.62), .down)
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

    func testSelectionGeometryDoesNotScaleGhosttyPointCoordinatesTwice() throws {
        // Ghostty reports a single-row selection at its text baseline (y: 480),
        // which lies inside row 28 of a 17pt grid with 2pt top padding.
        let geometry = try XCTUnwrap(TerminalSelectionGeometry(
            topLeft: CGPoint(x: 20, y: 480),
            bottomRight: CGPoint(x: 140, y: 480),
            cellWidthPixels: 24,
            cellHeightPixels: 51,
            displayScale: 3,
            renderOrigin: CGPoint(x: 3, y: 2)
        ))

        XCTAssertEqual(geometry.startAnchor, CGPoint(x: 23, y: 480))
        XCTAssertEqual(geometry.endAnchor, CGPoint(x: 143, y: 497))
        XCTAssertEqual(geometry.rect, CGRect(x: 23, y: 480, width: 120, height: 17))
        XCTAssertEqual(geometry.cellSize, CGSize(width: 8, height: 17))
    }

    func testSelectionGeometrySnapsBaselinesToRowEdgesAcrossRows() throws {
        // Rows are 17pt tall below 2pt of padding; each baseline sits 13pt
        // into its row. The selection covers rows 0 through 2.
        let geometry = try XCTUnwrap(TerminalSelectionGeometry(
            topLeft: CGPoint(x: 18, y: 15),
            bottomRight: CGPoint(x: 50, y: 49),
            cellWidthPixels: 24,
            cellHeightPixels: 51,
            displayScale: 3,
            renderOrigin: .zero
        ))

        XCTAssertEqual(geometry.startAnchor, CGPoint(x: 18, y: 2))
        XCTAssertEqual(geometry.endAnchor, CGPoint(x: 50, y: 53))
        XCTAssertEqual(geometry.rect.minY, 2)
        XCTAssertEqual(geometry.rect.height, 51)
    }

    func testSelectionPressPointsStayInsideTheirEndCells() throws {
        let geometry = try XCTUnwrap(TerminalSelectionGeometry(
            topLeft: CGPoint(x: 18, y: 15),
            bottomRight: CGPoint(x: 50, y: 49),
            cellWidthPixels: 24,
            cellHeightPixels: 51,
            displayScale: 3,
            renderOrigin: .zero
        ))

        // The first cell spans x 18..<26 on row 0 (y 2..<19) and the last cell
        // spans x 42..<50 on row 2 (y 36..<53). Ghostty keeps the clicked cell
        // only when the press lands on the outer side of its 60% threshold.
        XCTAssertEqual(geometry.startPressPoint.x, 18.8, accuracy: 0.0001)
        XCTAssertEqual(geometry.startPressPoint.y, 10.5, accuracy: 0.0001)
        XCTAssertEqual(geometry.endPressPoint.x, 49.2, accuracy: 0.0001)
        XCTAssertEqual(geometry.endPressPoint.y, 44.5, accuracy: 0.0001)
    }

    func testSelectionGeometryRejectsMissingCellMetrics() {
        XCTAssertNil(TerminalSelectionGeometry(
            topLeft: CGPoint(x: 0, y: 15),
            bottomRight: CGPoint(x: 8, y: 15),
            cellWidthPixels: 0,
            cellHeightPixels: 51,
            displayScale: 3,
            renderOrigin: .zero
        ))
    }

    func testClickResetPointIsTwoCellsAwayInsideTheSurface() {
        let cell = CGSize(width: 8, height: 17)
        let surface = CGSize(width: 100, height: 100)

        XCTAssertEqual(
            TerminalClickSequence.resetPoint(awayFrom: CGPoint(x: 10, y: 10), cellSize: cell, surfaceSize: surface),
            CGPoint(x: 26, y: 10)
        )
        XCTAssertEqual(
            TerminalClickSequence.resetPoint(awayFrom: CGPoint(x: 95, y: 10), cellSize: cell, surfaceSize: surface),
            CGPoint(x: 79, y: 10)
        )
    }

    func testClickResetPointFallsBackToVerticalOffsetOnNarrowSurfaces() {
        let reset = TerminalClickSequence.resetPoint(
            awayFrom: CGPoint(x: 5, y: 5),
            cellSize: CGSize(width: 8, height: 17),
            surfaceSize: CGSize(width: 10, height: 100)
        )

        XCTAssertEqual(reset, CGPoint(x: 5, y: 39))
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

    func testSelectionDoesNotInjectCopyIntoToolbar() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .paste])

        XCTAssertEqual(toolbar.displayedButtons, [.ctrl, .paste])

        toolbar.setSelectionAvailable(true)

        XCTAssertEqual(toolbar.displayedButtons, [.ctrl, .paste])

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
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .paste])
        toolbar.handleButtonTap(.ctrl)

        toolbar.apply(buttons: [.ctrl, .arrowUp, .paste], chip: nil)

        XCTAssertEqual(toolbar.activeModifiers, ["ctrl"])
    }

    func testRemovedModifierDoesNotSurviveToolbarCustomization() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .paste])
        toolbar.handleButtonTap(.ctrl)

        // Switching key sets (or editing one) drops modifiers the new layout lacks.
        toolbar.apply(buttons: [.arrowUp, .paste], chip: nil)

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

    // MARK: System keyboard text input

    func testTextInputDocumentAlwaysHasDeletableContextBeforeTheCaret() {
        let document = TerminalTextInputDocument()

        // The system keyboard only auto-repeats delete when the document it
        // inspects has text before the caret.
        XCTAssertEqual(document.length, 1)
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(document.text(in: NSRange(location: 0, length: 1)), TerminalTextInputDocument.placeholder)
        XCTAssertNil(document.markedRange)
    }

    func testTextInputDocumentPlaceholderCannotTriggerKeyboardShortcuts() {
        let placeholder = TerminalTextInputDocument.placeholder
        // Neither Unicode whitespace (double-space period) nor a letter
        // (autocapitalization). Foundation's whitespace set includes U+200B,
        // so check the Unicode properties directly.
        XCTAssertTrue(placeholder.unicodeScalars.allSatisfy { !$0.properties.isWhitespace })
        XCTAssertTrue(placeholder.unicodeScalars.allSatisfy { !$0.properties.isAlphabetic })
    }

    func testTextInputDocumentTracksAndCommitsComposition() {
        var document = TerminalTextInputDocument()

        document.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(document.markedRange, NSRange(location: 1, length: 3))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(document.text(in: document.markedRange!), "にほん")

        XCTAssertTrue(document.deleteBackwardInMarkedText())
        XCTAssertEqual(document.markedText, "にほ")

        XCTAssertEqual(document.commitMarkedText(), "にほ")
        XCTAssertFalse(document.hasMarkedText)
        XCTAssertFalse(document.deleteBackwardInMarkedText())
        XCTAssertEqual(document.length, 1)
    }

    func testTextInputDocumentDeleteHonorsMarkedCaret() {
        var document = TerminalTextInputDocument()
        document.setMarkedText("abc", selectedRange: NSRange(location: 1, length: 0))

        XCTAssertTrue(document.deleteBackwardInMarkedText())
        XCTAssertEqual(document.markedText, "bc")
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 0))

        // Caret at the start of the composition: consumed, nothing removed.
        XCTAssertTrue(document.deleteBackwardInMarkedText())
        XCTAssertEqual(document.markedText, "bc")
    }

    func testTextInputDocumentDeleteRemovesMarkedSelection() {
        var document = TerminalTextInputDocument()
        document.setMarkedText("abc", selectedRange: NSRange(location: 0, length: 2))

        XCTAssertTrue(document.deleteBackwardInMarkedText())
        XCTAssertEqual(document.markedText, "c")
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 0))
    }

    func testTextInputDocumentDeleteRemovesWholeComposedCharacter() {
        var document = TerminalTextInputDocument()
        document.setMarkedText("a👍🏽", selectedRange: NSRange(location: 5, length: 0))

        XCTAssertTrue(document.deleteBackwardInMarkedText())
        XCTAssertEqual(document.markedText, "a")
    }

    func testTextInputDocumentReplacesWithinComposition() {
        var document = TerminalTextInputDocument()
        document.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))

        // Document offsets: the placeholder occupies 0, "abc" occupies 1..<4.
        XCTAssertTrue(document.replaceInMarkedText(NSRange(location: 2, length: 1), with: "X"))
        XCTAssertEqual(document.markedText, "aXc")
        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 0))

        XCTAssertTrue(document.replaceInMarkedText(NSRange(location: 1, length: 1), with: ""))
        XCTAssertEqual(document.markedText, "Xc")

        // Ranges overlapping the placeholder only touch the composition.
        XCTAssertTrue(document.replaceInMarkedText(NSRange(location: 0, length: 2), with: "Y"))
        XCTAssertEqual(document.markedText, "Yc")

        XCTAssertTrue(document.replaceInMarkedText(NSRange(location: 1, length: 2), with: ""))
        XCTAssertFalse(document.hasMarkedText)
        XCTAssertFalse(document.replaceInMarkedText(NSRange(location: 1, length: 0), with: "Z"))
    }

    func testReplaceWithinCompositionStaysLocal() throws {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        surface.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        let middle = try XCTUnwrap(surface.textRange(
            from: try XCTUnwrap(surface.position(from: surface.beginningOfDocument, offset: 2)),
            to: try XCTUnwrap(surface.position(from: surface.beginningOfDocument, offset: 3))
        ))
        surface.replace(middle, withText: "X")
        XCTAssertTrue(sent.isEmpty)

        surface.unmarkText()
        XCTAssertEqual(sent, [Data("aXc".utf8)])
    }

    func testTextInputDocumentClampsOutOfBoundsRequests() {
        var document = TerminalTextInputDocument()
        document.setMarkedText("ab", selectedRange: NSRange(location: 9, length: 9))

        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(document.text(in: NSRange(location: 2, length: 50)), "b")
        XCTAssertEqual(document.text(in: NSRange(location: -4, length: 5)), TerminalTextInputDocument.placeholder)
        XCTAssertEqual(document.text(in: NSRange(location: -4, length: 1)), "")
    }

    func testRepeatedDeleteBackwardSendsOneBackspaceEach() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        for _ in 0..<3 {
            surface.deleteBackward()
        }

        XCTAssertEqual(sent, Array(repeating: Data([0x7F]), count: 3))
        // The keyboard keeps seeing deletable context after every delete.
        XCTAssertTrue(surface.hasText)
        XCTAssertEqual(surface.offset(from: surface.beginningOfDocument, to: surface.endOfDocument), 1)
    }

    func testCompositionIsEditedLocallyAndSentOnlyWhenCommitted() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        surface.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        surface.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0))
        surface.deleteBackward()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNotNil(surface.markedTextRange)

        surface.unmarkText()

        XCTAssertEqual(sent, [Data("か".utf8)])
        XCTAssertNil(surface.markedTextRange)
    }

    func testInsertTextReplacesCompositionInsteadOfCommittingIt() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        surface.setMarkedText("kan", selectedRange: NSRange(location: 3, length: 0))
        surface.insertText("漢")

        XCTAssertEqual(sent, [Data("漢".utf8)])
        XCTAssertNil(surface.markedTextRange)
    }

    func testTextInputPositionsStayInsideTheDocument() throws {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)
        let start = surface.beginningOfDocument
        let end = surface.endOfDocument

        XCTAssertNil(surface.position(from: end, offset: 1))
        XCTAssertNil(surface.position(from: start, offset: -1))
        XCTAssertEqual(surface.compare(start, to: end), .orderedAscending)
        let range = try XCTUnwrap(surface.textRange(from: end, to: start))
        XCTAssertEqual(surface.text(in: range), TerminalTextInputDocument.placeholder)

        // The keyboard cannot move the caret into remote content.
        surface.selectedTextRange = range
        XCTAssertEqual(surface.offset(from: start, to: try XCTUnwrap(surface.selectedTextRange).start), 1)
    }

    func testTerminalTextInputDisablesAutomaticTextChanges() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: false)

        XCTAssertEqual(surface.autocorrectionType, .no)
        XCTAssertEqual(surface.spellCheckingType, .no)
        XCTAssertEqual(surface.smartQuotesType, .no)
        XCTAssertEqual(surface.smartDashesType, .no)
        XCTAssertEqual(surface.smartInsertDeleteType, .no)
        XCTAssertEqual(surface.inlinePredictionType, .no)
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
        XCTAssertFalse(surface.toolbarAccessory.displayedButtons.contains(.copy))
    }

    func testStationaryLongPressSelectsAWordForNativeCopyMenu() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("hello from the remote terminal".utf8))
        let point = CGPoint(x: 14, y: 8)

        surface.beginLongPressSelection(at: point)
        surface.endLongPressSelection(at: point, cancelled: false)

        XCTAssertTrue(surface.hasSelection())
        XCTAssertFalse(surface.readSelection()?.isEmpty ?? true)
        XCTAssertTrue(surface.toolbarAccessory.selectionAvailable)
    }

    func testLongPressDragSelectsRangeForNativeCopyMenu() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("drag across this terminal output".utf8))

        surface.beginLongPressSelection(at: CGPoint(x: 8, y: 8))
        surface.updateLongPressSelection(at: CGPoint(x: 120, y: 8))
        surface.endLongPressSelection(at: CGPoint(x: 120, y: 8), cancelled: false)

        XCTAssertTrue(surface.hasSelection())
        XCTAssertFalse(surface.readSelection()?.isEmpty ?? true)
    }

    func testDraggingSelectionHandleKeepsCharacterGranularity() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("alpha beta gamma delta".utf8))
        let cell = try XCTUnwrap(surface.currentCellSize)

        XCTAssertTrue(surface.selectWord(at: CGPoint(x: cell.width * 2.5, y: cell.height / 2)))
        XCTAssertEqual(surface.readSelection(), "alpha")

        // Rapid drag updates used to synthesize a press per update, which
        // Ghostty counted as double and triple clicks (word and line selection).
        surface.dragSelectionHandle(isStart: false, state: .began, translation: .zero)
        for step in 1...5 {
            let translation = CGPoint(x: cell.width * CGFloat(step) / 2, y: 0)
            surface.dragSelectionHandle(isStart: false, state: .changed, translation: translation)
        }
        surface.dragSelectionHandle(isStart: false, state: .ended, translation: CGPoint(x: cell.width * 3, y: 0))

        XCTAssertEqual(surface.readSelection(), "alpha be")
    }

    func testDraggingStartHandleKeepsTheSelectionEnd() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("alpha beta gamma delta".utf8))
        let cell = try XCTUnwrap(surface.currentCellSize)

        XCTAssertTrue(surface.selectWord(at: CGPoint(x: cell.width * 13.5, y: cell.height / 2)))
        XCTAssertEqual(surface.readSelection(), "gamma")

        surface.dragSelectionHandle(isStart: true, state: .began, translation: .zero)
        surface.dragSelectionHandle(isStart: true, state: .changed, translation: CGPoint(x: -cell.width, y: 0))
        surface.dragSelectionHandle(isStart: true, state: .ended, translation: CGPoint(x: -cell.width * 2, y: 0))

        XCTAssertEqual(surface.readSelection(), "a gamma")
    }

    func testHandleDragSurvivesMomentarilyEmptySelection() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("alpha beta gamma delta".utf8))
        let cell = try XCTUnwrap(surface.currentCellSize)

        XCTAssertTrue(surface.selectWord(at: CGPoint(x: cell.width * 2.5, y: cell.height / 2)))
        XCTAssertEqual(surface.readSelection(), "alpha")

        // Dragging the end handle back onto the fixed start empties Ghostty's
        // selection mid-drag. The drag must keep its synthesized press so it
        // can carry on and release the button when it ends.
        surface.dragSelectionHandle(isStart: false, state: .began, translation: .zero)
        surface.dragSelectionHandle(isStart: false, state: .changed, translation: CGPoint(x: -cell.width * 5, y: 0))
        XCTAssertFalse(surface.hasSelection())
        XCTAssertNotNil(selectionHandle(in: surface, label: "Selection end"))

        surface.dragSelectionHandle(isStart: false, state: .changed, translation: CGPoint(x: cell.width * 3, y: 0))
        surface.dragSelectionHandle(isStart: false, state: .ended, translation: CGPoint(x: cell.width * 3, y: 0))

        XCTAssertEqual(surface.readSelection(), "alpha be")
    }

    func testOverlappingHandleTouchTargetsPreferTheNearestKnob() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("a bc".utf8))
        let cell = try XCTUnwrap(surface.currentCellSize)

        XCTAssertTrue(surface.selectWord(at: CGPoint(x: cell.width * 0.5, y: cell.height / 2)))
        XCTAssertEqual(surface.readSelection(), "a")

        let start = try XCTUnwrap(selectionHandle(in: surface, label: "Selection start"))
        let end = try XCTUnwrap(selectionHandle(in: surface, label: "Selection end"))
        let knob: CGFloat = 12 // TerminalSelectionHandleView.knobDiameter
        let startKnob = CGPoint(x: start.frame.midX, y: start.frame.minY + knob / 2)
        let endKnob = CGPoint(x: end.frame.midX, y: end.frame.maxY - knob / 2)

        // A one-character selection puts both handles' touch targets on top of
        // each other; each knob must still reach its own handle.
        XCTAssertTrue(start.frame.intersects(end.frame))
        XCTAssertTrue(surface.hitTest(startKnob, with: nil) === start)
        XCTAssertTrue(surface.hitTest(endKnob, with: nil) === end)
    }

    private func selectionHandle(in surface: UIView, label: String) -> UIView? {
        surface.subviews.first { $0.accessibilityLabel == label }
    }

    func testNativeEditMenuOffersCopyPasteAndSelectAll() throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        surface.writeRemoteOutput(Array("native terminal edit menu".utf8))
        surface.selectAll(nil)
        pasteboard.string = "paste me"
        let interaction = UIEditMenuInteraction(delegate: surface)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)

        let menu = try XCTUnwrap(surface.editMenuInteraction(
            interaction,
            menuFor: configuration,
            suggestedActions: []
        ))
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }

        XCTAssertEqual(titles, ["Copy", "Paste", "Select All"])
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
        await waitUntil { String(data: sent.reduce(Data(), +), encoding: .utf8) == "echo first\recho second" }

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
        // The bracketed paste can arrive in several chunks; wait for the end marker.
        await waitUntil {
            String(data: sent.reduce(Data(), +), encoding: .utf8)?.hasSuffix("\u{1B}[201~") == true
        }

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
        await waitUntil { String(data: sent.reduce(Data(), +), encoding: .utf8) == "echo intentional local paste" }

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
        await waitUntil {
            String(data: sent.reduce(Data(), +), encoding: .utf8)?.contains(Data("private clipboard".utf8).base64EncodedString()) == true
        }

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
        await waitUntil {
            String(data: sent.reduce(Data(), +), encoding: .utf8)?.contains(Data("private clipboard".utf8).base64EncodedString()) == true
        }

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

    func testLiveOSC9RoutesGhosttyDesktopNotificationToSurface() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 400))
        var received: TerminalDesktopNotification?
        surface.onDesktopNotification = { received = $0 }

        surface.writeRemoteOutput(Array("\u{1B}]9;Agent turn complete\u{07}".utf8))
        await waitUntil { received != nil }

        XCTAssertEqual(received?.body ?? received?.title, "Agent turn complete")
    }

    func testFingerDragScrollsPrimaryScreenBackThroughScrollback() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 240))
        let ghosttySurface = try XCTUnwrap(surface.surface)
        let output = (0..<100).map { "scrollback line \($0)\r\n" }.joined()
        surface.writeRemoteOutput(Array(output.utf8))
        await waitUntil { ghostty_surface_scrollback_offset(ghosttySurface) > 0 }
        let bottomOffset = ghostty_surface_scrollback_offset(ghosttySurface)

        surface.scrollByTouchTranslation(120)
        await waitUntil { ghostty_surface_scrollback_offset(ghosttySurface) < bottomOffset }

        XCTAssertLessThan(ghostty_surface_scrollback_offset(ghosttySurface), bottomOffset)
    }

    func testFingerDragUsesNativeAlternateScreenScrolling() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 240))
        let ghosttySurface = try XCTUnwrap(surface.surface)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }
        surface.writeRemoteOutput(Array("\u{1B}[?1049h\u{1B}[?1007h".utf8))
        await waitUntil { ghostty_surface_is_alternate_screen(ghosttySurface) }

        surface.scrollByTouchTranslation(120)
        await waitUntil { !sent.isEmpty }

        let input = sent.reduce(Data(), +)
        XCTAssertTrue(
            input.range(of: Data("\u{1B}[A".utf8)) != nil
                || input.range(of: Data("\u{1B}OA".utf8)) != nil
        )
    }

    func testFingerDragSendsMouseWheelEventsToTmuxMouseMode() async throws {
        let surface = try makeLiveSurface(size: CGSize(width: 390, height: 240))
        let ghosttySurface = try XCTUnwrap(surface.surface)
        var sent: [Data] = []
        surface.onInputData = { sent.append($0) }

        // tmux with `set -g mouse on` enables alternate screen, button-event
        // mouse tracking, and SGR mouse encoding on the outer terminal.
        surface.writeRemoteOutput(Array("\u{1B}[?1049h\u{1B}[?1002h\u{1B}[?1006h".utf8))
        await waitUntil { ghostty_surface_mouse_captured(ghosttySurface) }

        surface.scrollByTouchTranslation(120, at: CGPoint(x: 20, y: 20))
        await waitUntil { !sent.isEmpty }

        let input = String(decoding: sent.reduce(Data(), +), as: UTF8.self)
        XCTAssertTrue(input.contains("\u{1B}[<64;"), "Expected an SGR wheel-up event, got \(input.debugDescription)")
    }

    func testDesktopNotificationClassifiesAttentionAndBoundsUntrustedText() throws {
        let notification = try XCTUnwrap(TerminalDesktopNotification(
            title: " Codex\npermission\u{07}required ",
            body: String(repeating: "🟢", count: 2_000)
        ))

        XCTAssertEqual(notification.title, "Codex permission required")
        XCTAssertEqual(notification.agentEventKind, .approvalRequested)
        XCTAssertLessThanOrEqual(notification.title.utf8.count, 512)
        XCTAssertLessThanOrEqual(try XCTUnwrap(notification.body).utf8.count, 4_096)
        XCTAssertTrue(notification.agentEventEnvelope.isValid)
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
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            GhosttyRuntimeController.shared.tick()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

final class TerminalHeaderContextTests: XCTestCase {
    private func subtitle(title: String?, pwd: String? = nil) -> String? {
        TerminalHeaderContext.subtitle(
            title: title,
            workingDirectory: pwd,
            username: "fcoury",
            hostname: "m5pro.local",
            serverName: "m5pro"
        )
    }

    func testProgramTitleWins() {
        XCTAssertEqual(subtitle(title: "vim main.rs", pwd: "/Users/fcoury/code"), "vim main.rs")
    }

    func testStripsUserHostPrefix() {
        XCTAssertEqual(subtitle(title: "fcoury@m5pro: ~/code/hoshi"), "~/code/hoshi")
        XCTAssertEqual(subtitle(title: "fcoury@m5pro.local:~"), "~")
    }

    func testRedundantTitleFallsBackToWorkingDirectory() {
        XCTAssertEqual(subtitle(title: "fcoury@m5pro", pwd: "/Users/fcoury/code/hoshi"), "~/code/hoshi")
        XCTAssertEqual(subtitle(title: "m5pro", pwd: "/tmp"), "/tmp")
        XCTAssertNil(subtitle(title: "  ", pwd: nil))
    }

    func testWorkingDirectoryReportParsing() {
        XCTAssertEqual(TerminalHeaderContext.path(fromWorkingDirectoryReport: "file://m5pro/Users/fcoury/My%20Docs"), "/Users/fcoury/My Docs")
        XCTAssertEqual(TerminalHeaderContext.path(fromWorkingDirectoryReport: "/var/log"), "/var/log")
        XCTAssertNil(TerminalHeaderContext.path(fromWorkingDirectoryReport: ""))
    }

    func testHomeAbbreviation() {
        XCTAssertEqual(TerminalHeaderContext.abbreviatePath("/home/fcoury/src", username: "fcoury"), "~/src")
        XCTAssertEqual(TerminalHeaderContext.abbreviatePath("/home/fcoury2", username: "fcoury"), "/home/fcoury2")
        XCTAssertEqual(TerminalHeaderContext.abbreviatePath("/root", username: "root"), "~")
    }

    func testScrollbackPosition() {
        XCTAssertFalse(TerminalScrollbackPosition.isScrolledBack(total: 40, offset: 0, len: 40))
        XCTAssertFalse(TerminalScrollbackPosition.isScrolledBack(total: 500, offset: 460, len: 40))
        XCTAssertTrue(TerminalScrollbackPosition.isScrolledBack(total: 500, offset: 100, len: 40))
    }

    func testLatencyQualityAndText() {
        XCTAssertEqual(ConnectionLatencyQuality(roundTripTime: 0.045), .good)
        XCTAssertEqual(ConnectionLatencyQuality(roundTripTime: 0.2), .fair)
        XCTAssertEqual(ConnectionLatencyQuality(roundTripTime: 0.6), .poor)
        XCTAssertEqual(ConnectionLatencyQuality.displayText(for: 0.0424), "42ms")
        XCTAssertEqual(ConnectionLatencyQuality.displayText(for: 1.25), "1.2s")
    }

    func testMoshRoundTripSampling() {
        XCTAssertNil(MoshRoundTripEstimator.sample(now: 100, reply: 0xFFFF))
        XCTAssertEqual(MoshRoundTripEstimator.sample(now: 1_050, reply: 1_000), 0.05)
        // 16-bit clock wraparound.
        XCTAssertEqual(MoshRoundTripEstimator.sample(now: 20, reply: 65_516), 0.04)
        // Stale echo is ignored, matching mosh.
        XCTAssertNil(MoshRoundTripEstimator.sample(now: 9_000, reply: 1_000))
    }

    func testMoshRoundTripSmoothing() {
        var estimator = MoshRoundTripEstimator()
        XCTAssertEqual(estimator.record(0.1), 0.1)
        XCTAssertEqual(estimator.record(0.2), 0.1125, accuracy: 1e-9)
        estimator.reset()
        XCTAssertNil(estimator.smoothed)
    }
}

final class KeyChordTests: XCTestCase {
    private func bytes(_ binding: String, prefix: String? = nil) throws -> [UInt8] {
        try KeyChord.encode(binding, prefix: prefix)
    }

    func testControlAltShiftChords() throws {
        XCTAssertEqual(try bytes("ctrl+s"), [0x13])
        XCTAssertEqual(try bytes("ctrl+["), [0x1B])
        XCTAssertEqual(try bytes("alt+h"), [0x1B, 0x68])
        XCTAssertEqual(try bytes("shift+b"), Array("B".utf8))
        XCTAssertEqual(try bytes("shift+tab"), Array("\u{1B}[Z".utf8))
        XCTAssertEqual(try bytes("alt+enter"), [0x1B, 0x0D])
    }

    func testNamedAndModifiedSpecialKeys() throws {
        XCTAssertEqual(try bytes("up"), Array("\u{1B}[A".utf8))
        XCTAssertEqual(try bytes("alt+up"), Array("\u{1B}[1;3A".utf8))
        XCTAssertEqual(try bytes("ctrl+left"), Array("\u{1B}[1;5D".utf8))
        XCTAssertEqual(try bytes("pgdn"), Array("\u{1B}[6~".utf8))
        XCTAssertEqual(try bytes("f1"), Array("\u{1B}OP".utf8))
        XCTAssertEqual(try bytes("f5"), Array("\u{1B}[15~".utf8))
    }

    func testPrefixExpansion() throws {
        XCTAssertEqual(try bytes("prefix+d", prefix: "ctrl+s"), [0x13, 0x64])
        XCTAssertEqual(try bytes("prefix+shift+b", prefix: "ctrl+s"), [0x13, 0x42])
        XCTAssertEqual(try bytes("prefix+minus", prefix: "ctrl+b"), [0x02, 0x2D])
        XCTAssertEqual(try bytes("prefix+{", prefix: "ctrl+b"), [0x02, 0x7B])
        XCTAssertEqual(try bytes("prefix+;", prefix: "ctrl+b"), [0x02, 0x3B])
        XCTAssertEqual(try bytes("prefix+left", prefix: "ctrl+b"), [0x02] + Array("\u{1B}[D".utf8))
        XCTAssertEqual(try bytes("prefix", prefix: "ctrl+a"), [0x01])
        XCTAssertThrowsError(try bytes("prefix+d")) { error in
            XCTAssertEqual(error as? KeyChord.EncodingError, .missingPrefix)
        }
    }

    func testSequencesAndLiterals() throws {
        XCTAssertEqual(try bytes(":w enter"), Array(":w\r".utf8))
        XCTAssertEqual(try bytes("esc colon q"), [0x1B] + Array(":q".utf8))
        XCTAssertEqual(try bytes("+"), Array("+".utf8))
    }

    func testRejectsRangesAndUnknownModifiers() {
        XCTAssertThrowsError(try bytes("prefix+1..9", prefix: "ctrl+b"))
        XCTAssertThrowsError(try bytes("hyper+x"))
        XCTAssertThrowsError(try bytes("   "))
    }

    func testTmuxNotation() {
        XCTAssertEqual(KeyChord.chord(fromTmuxNotation: "^B"), "ctrl+b")
        XCTAssertEqual(KeyChord.chord(fromTmuxNotation: "C-a"), "ctrl+a")
        XCTAssertNil(KeyChord.chord(fromTmuxNotation: "F12"))
    }

    func testDisplayString() {
        XCTAssertEqual(KeyChord.displayString("ctrl+s"), "⌃s")
        XCTAssertEqual(KeyChord.displayString("prefix+shift+b"), "Pfx ⇧b")
    }
}

final class HerdrKeyImportTests: XCTestCase {
    private let sampleConfig = """
    onboarding = false

    [session]
    resume_agents_on_restore = true

    [keys]
    prefix = "ctrl+s"

    # Management and navigation.
    workspace_picker = ["prefix+b", "prefix+o"]
    goto = "prefix+w"
    detach = "prefix+minus"
    previous_workspace = ["prefix+left", "alt+up", "alt+h"]
    next_agent = "prefix+down"
    focus_agent = "prefix+alt+1..9"
    toggle_sidebar = "prefix+shift+b" # moved
    switch_tab = [
      "alt+1..9",
      "prefix+1..9",
    ]
    split_vertical = "prefix+d"
    split_horizontal = "prefix+s"
    last_pane = "prefix+;"
    close_pane = ""

    [ui]
    pane_borders = "auto"
    """

    func testParsesKeysSectionOnly() {
        let keys = HerdrKeyImport.parseKeysSection(sampleConfig)
        XCTAssertEqual(keys["prefix"], ["ctrl+s"])
        XCTAssertEqual(keys["workspace_picker"], ["prefix+b", "prefix+o"])
        XCTAssertEqual(keys["toggle_sidebar"], ["prefix+shift+b"])
        XCTAssertEqual(keys["switch_tab"], ["alt+1..9", "prefix+1..9"])
        XCTAssertEqual(keys["last_pane"], ["prefix+;"])
        XCTAssertEqual(keys["close_pane"], [""])
        XCTAssertNil(keys["pane_borders"])
        XCTAssertNil(keys["resume_agents_on_restore"])
    }

    private func herdrProfile(config: String?) -> KeyProfile {
        let result = HerdrKeyImport.importConfig(config)
        var profile = KeyProfile.herdr
        profile.prefix = result.prefix
        profile.herdrBindings = result.bindings
        return profile
    }

    private func resolvedBytes(_ action: String, in profile: KeyProfile) -> [UInt8]? {
        guard let catalogAction = HerdrKeyImport.action(named: action) else { return nil }
        return profile.resolve(HerdrKeyImport.button(for: catalogAction))?.bytes
    }

    func testImportUsesConfiguredPrefixAndBindings() {
        let profile = herdrProfile(config: sampleConfig)
        XCTAssertEqual(profile.prefix, "ctrl+s")
        XCTAssertEqual(resolvedBytes("workspace_picker", in: profile), [0x13, 0x62])
        XCTAssertEqual(resolvedBytes("split_vertical", in: profile), [0x13, 0x64])
        XCTAssertEqual(resolvedBytes("toggle_sidebar", in: profile), [0x13, 0x42])
        XCTAssertEqual(resolvedBytes("previous_workspace", in: profile), [0x13] + Array("\u{1B}[D".utf8))
        XCTAssertEqual(resolvedBytes("next_agent", in: profile), [0x13] + Array("\u{1B}[B".utf8))
        XCTAssertEqual(resolvedBytes("last_pane", in: profile), [0x13, 0x3B])
        // Explicitly unbound in config.
        XCTAssertNil(resolvedBytes("close_pane", in: profile))
        // Unset in config, falls back to Herdr's default with the imported prefix.
        XCTAssertEqual(resolvedBytes("zoom", in: profile), [0x13, 0x7A])
        // Unbound by default and not configured.
        XCTAssertNil(resolvedBytes("previous_agent", in: profile))
    }

    func testDefaultsWithoutConfig() {
        let result = HerdrKeyImport.importConfig(nil)
        XCTAssertEqual(result.prefix, "ctrl+b")
        XCTAssertEqual(result.configuredActionCount, 0)
        XCTAssertEqual(resolvedBytes("split_horizontal", in: herdrProfile(config: nil)), [0x02, 0x2D])
    }

    func testUnboundActionsAreHiddenFromToolbar() {
        let profile = herdrProfile(config: sampleConfig)
        let ids = Set(profile.resolvedKeys.map(\.id))
        XCTAssertTrue(ids.contains("herdr-split_vertical"))
        XCTAssertFalse(ids.contains("herdr-close_pane"))
        XCTAssertFalse(ids.contains("herdr-previous_agent"))
    }

    func testReimportKeepsSelectionAndOrder() {
        var profile = herdrProfile(config: sampleConfig)
        let customOrder = [
            HerdrKeyImport.button(for: HerdrKeyImport.action(named: "zoom")!),
            .esc,
            HerdrKeyImport.button(for: HerdrKeyImport.action(named: "new_workspace")!),
        ]
        profile.keys = customOrder

        let remapped = sampleConfig.replacingOccurrences(of: "prefix = \"ctrl+s\"", with: "prefix = \"ctrl+a\"")
        let result = HerdrKeyImport.importConfig(remapped)
        profile.prefix = result.prefix
        profile.herdrBindings = result.bindings

        XCTAssertEqual(profile.keys.map(\.id), customOrder.map(\.id))
        XCTAssertEqual(profile.resolvedKeys.first?.bytes, [0x01, 0x7A])
        XCTAssertEqual(profile.resolvedKeys.last?.bytes, [0x01, 0x4E])
    }

    func testZoomHonorsLegacyFullscreenName() {
        let profile = herdrProfile(config: "[keys]\nprefix = \"ctrl+b\"\nfullscreen = \"prefix+f\"\n")
        XCTAssertEqual(resolvedBytes("zoom", in: profile), [0x02, 0x66])
    }

    func testMigratesLegacyCopiedChordKeys() {
        let legacy: [ToolbarButton] = [
            .esc,
            .custom(label: "Split |", chord: "prefix+d", id: "custom-herdr-split_vertical"),
            .custom(label: "Pfx", chord: "prefix", id: "custom-herdr-prefix"),
        ]
        let migrated = HerdrKeyImport.migrateLegacyKeys(legacy)
        XCTAssertEqual(migrated.map(\.id), ["esc", "herdr-split_vertical", "custom-herdr-prefix"])
        XCTAssertEqual(migrated[1].herdrAction, "split_vertical")
        XCTAssertNil(migrated[2].herdrAction)
    }

    func testReadConfigCommandIsShellIndependent() {
        // fish and other non-POSIX login shells reject ${VAR:-default}; the script must run under sh.
        XCTAssertTrue(HerdrKeyImport.readConfigCommand.hasPrefix("sh -c '"))
        XCTAssertTrue(HerdrKeyImport.readConfigCommand.hasSuffix("'"))
        let script = HerdrKeyImport.readConfigCommand.dropFirst("sh -c '".count).dropLast()
        XCTAssertFalse(script.contains("'"), "single quotes would break the sh -c wrapper")
    }

    func testCatalogDefaultsEncode() {
        for action in HerdrKeyImport.catalog {
            for binding in action.defaults {
                XCTAssertTrue(KeyChord.isValid(binding, prefix: "ctrl+b"), "\(action.name): \(binding)")
            }
        }
        XCTAssertEqual(Set(HerdrKeyImport.catalog.map(\.name)).count, HerdrKeyImport.catalog.count)
    }
}

@MainActor
final class KeyProfileTests: XCTestCase {
    private func profiles() -> [KeyProfile] {
        KeyProfile.builtIns
    }

    func testResolverMatchesTitleWords() {
        XCTAssertEqual(KeyProfileResolver.resolve(title: "nvim main.rs", pinnedID: nil, autoSwitch: true, profiles: profiles()).id, KeyProfile.vimID)
        XCTAssertEqual(KeyProfileResolver.resolve(title: "✳ Claude Code", pinnedID: nil, autoSwitch: true, profiles: profiles()).id, KeyProfile.agentID)
        XCTAssertEqual(KeyProfileResolver.resolve(title: "herdr · hoshi", pinnedID: nil, autoSwitch: true, profiles: profiles()).id, KeyProfile.herdrID)
        // Whole-word matching: "desktop" must not select the Pager set via "top".
        XCTAssertEqual(KeyProfileResolver.resolve(title: "~/Desktop", pinnedID: nil, autoSwitch: true, profiles: profiles()).id, KeyProfile.shellID)
    }

    func testHerdrAttachmentSelectsHerdrUnlessPinned() {
        XCTAssertEqual(KeyProfileResolver.resolve(title: "claude", pinnedID: nil, attachedID: KeyProfile.herdrID, autoSwitch: true, profiles: profiles()).id, KeyProfile.herdrID)
        XCTAssertEqual(KeyProfileResolver.resolve(title: "claude", pinnedID: KeyProfile.agentID, attachedID: KeyProfile.herdrID, autoSwitch: true, profiles: profiles()).id, KeyProfile.agentID)
        XCTAssertEqual(KeyProfileResolver.resolve(title: "claude", pinnedID: nil, attachedID: KeyProfile.herdrID, autoSwitch: false, profiles: profiles()).id, KeyProfile.shellID)
    }

    func testPinAndAutoSwitch() {
        XCTAssertEqual(KeyProfileResolver.resolve(title: "vim", pinnedID: KeyProfile.herdrID, autoSwitch: true, profiles: profiles()).id, KeyProfile.herdrID)
        XCTAssertEqual(KeyProfileResolver.resolve(title: "vim", pinnedID: nil, autoSwitch: false, profiles: profiles()).id, KeyProfile.shellID)
    }

    func testBuiltInCustomKeysEncode() {
        for profile in profiles() {
            for key in profile.keys where key.isCustom {
                XCTAssertTrue(
                    KeyChord.isValid(key.chord ?? "", prefix: profile.prefix),
                    "\(profile.name) key \(key.label) does not encode"
                )
            }
        }
    }

    func testStorePersistsEditsAndPins() throws {
        let suiteName = "KeyProfileTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = KeyProfileStore(defaults: defaults)
        var herdr = try XCTUnwrap(store.profile(id: KeyProfile.herdrID))
        herdr.prefix = "ctrl+s"
        herdr.keys.append(.custom(label: "Split", chord: "prefix+d", id: "custom-test-split"))
        store.update(herdr)
        let serverID = UUID()
        store.pin(KeyProfile.herdrID, for: serverID)

        let reloaded = KeyProfileStore(defaults: defaults)
        let restored = try XCTUnwrap(reloaded.profile(id: KeyProfile.herdrID))
        XCTAssertEqual(restored.prefix, "ctrl+s")
        XCTAssertEqual(restored.resolvedKeys.last?.bytes, [0x13, 0x64])
        XCTAssertEqual(reloaded.resolve(title: "zsh", serverID: serverID).id, KeyProfile.herdrID)

        reloaded.pin(nil, for: serverID)
        XCTAssertEqual(reloaded.resolve(title: "zsh", serverID: serverID).id, KeyProfile.shellID)
    }

    func testStoreImportUpdatesBindingsOnly() throws {
        let suiteName = "KeyProfileTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = KeyProfileStore(defaults: defaults)
        var herdr = try XCTUnwrap(store.profile(id: KeyProfile.herdrID))
        herdr.keys = [HerdrKeyImport.button(for: HerdrKeyImport.action(named: "split_vertical")!)]
        store.update(herdr)

        store.updateHerdrBindings(prefix: "ctrl+s", bindings: ["split_vertical": ["prefix+d"]], source: "m5pro")

        let reloaded = try XCTUnwrap(KeyProfileStore(defaults: defaults).profile(id: KeyProfile.herdrID))
        XCTAssertEqual(reloaded.keys.map(\.id), ["herdr-split_vertical"])
        XCTAssertEqual(reloaded.herdrBindingsSource, "m5pro")
        XCTAssertEqual(reloaded.resolvedKeys.first?.bytes, [0x13, 0x64])
    }

    func testCustomButtonsRoundTripThroughCodable() throws {
        let button = ToolbarButton.custom(label: "Split", chord: "prefix+d", symbol: "rectangle.split.2x1", id: "custom-x")
        let decoded = try JSONDecoder().decode(ToolbarButton.self, from: JSONEncoder().encode(button))
        XCTAssertEqual(decoded, button)
        // Legacy payloads without the new fields still decode.
        let legacy = #"{"id":"esc","label":"Esc","bytes":[27],"category":"modifier"}"#
        let esc = try JSONDecoder().decode(ToolbarButton.self, from: Data(legacy.utf8))
        XCTAssertNil(esc.chord)
        XCTAssertEqual(esc.symbolName, nil)
    }
}
