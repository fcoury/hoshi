import XCTest
@testable import Hoshi

final class PressedKeyTextFilterTests: XCTestCase {
    private let a = Data("a".utf8), b = Data("b".utf8)

    func testInsertedTextForAPressedKeyIsSentOnce() {
        var filter = PressedKeyTextFilter()
        filter.recordPress(a, at: 0)
        XCTAssertTrue(filter.suppressesInsertedText(a, at: 0.01))
        // The press is matched; the same text again is new input.
        XCTAssertFalse(filter.suppressesInsertedText(a, at: 0.02))
    }

    func testFastTypingMatchesEachPressToItsText() {
        var filter = PressedKeyTextFilter()
        filter.recordPress(a, at: 0)
        filter.recordPress(b, at: 0.01)
        XCTAssertTrue(filter.suppressesInsertedText(a, at: 0.02))
        XCTAssertTrue(filter.suppressesInsertedText(b, at: 0.03))
    }

    func testLateTextFromABusyMainThreadIsStillMatched() {
        var filter = PressedKeyTextFilter()
        filter.recordPress(a, at: 0)
        XCTAssertTrue(filter.suppressesInsertedText(a, at: 0.2))
    }

    func testTextWithoutAPressIsSent() {
        var filter = PressedKeyTextFilter()
        XCTAssertFalse(filter.suppressesInsertedText(a, at: 0))
        filter.recordPress(a, at: 0)
        XCTAssertFalse(filter.suppressesInsertedText(b, at: 0.01))
        XCTAssertFalse(filter.suppressesInsertedText(a, at: PressedKeyTextFilter.window + 0.1))
    }
}
