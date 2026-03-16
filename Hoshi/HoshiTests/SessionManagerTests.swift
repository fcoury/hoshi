import XCTest
@testable import Hoshi

@MainActor
final class SessionManagerTests: XCTestCase {

    func testCreateSessionInsertsNewestFirst() {
        let manager = SessionManager()

        let first = manager.createSession(for: makeServer(name: "First"))
        let second = manager.createSession(for: makeServer(name: "Second"))
        let third = manager.createSession(for: makeServer(name: "Third"))

        XCTAssertEqual(manager.sessions.map(\.serverName), ["Third", "Second", "First"])
        XCTAssertEqual(manager.sessions.first?.id, third?.id)
        XCTAssertEqual(manager.sessions[1].id, second?.id)
        XCTAssertEqual(manager.sessions[2].id, first?.id)
    }

    func testSwitchToMovesExistingSessionToFront() {
        let manager = SessionManager()
        let first = manager.createSession(for: makeServer(name: "First"))!
        let second = manager.createSession(for: makeServer(name: "Second"))!
        let third = manager.createSession(for: makeServer(name: "Third"))!

        manager.switchTo(sessionID: first.id)

        XCTAssertEqual(manager.activeSessionID, first.id)
        XCTAssertEqual(manager.sessions.map(\.id), [first.id, third.id, second.id])
        XCTAssertGreaterThanOrEqual(first.lastAccessedAt, third.lastAccessedAt)
    }

    func testSwitchToFrontSessionKeepsOrderStable() {
        let manager = SessionManager()
        let first = manager.createSession(for: makeServer(name: "First"))!
        let second = manager.createSession(for: makeServer(name: "Second"))!

        let previousOrder = manager.sessions.map(\.id)
        let previousAccess = second.lastAccessedAt

        manager.switchTo(sessionID: second.id)

        XCTAssertEqual(manager.activeSessionID, second.id)
        XCTAssertEqual(manager.sessions.map(\.id), previousOrder)
        XCTAssertGreaterThanOrEqual(second.lastAccessedAt, previousAccess)
        XCTAssertEqual(manager.sessions[1].id, first.id)
    }

    func testCloseSessionPreservesRemainingOrder() async {
        let manager = SessionManager()
        let first = manager.createSession(for: makeServer(name: "First"))!
        let second = manager.createSession(for: makeServer(name: "Second"))!
        let third = manager.createSession(for: makeServer(name: "Third"))!

        manager.switchTo(sessionID: first.id)
        await manager.closeSession(id: third.id)

        XCTAssertEqual(manager.sessions.map(\.id), [first.id, second.id])
    }

    func testReturnToServerListKeepsConnectedSessionOrder() {
        let manager = SessionManager()
        let first = manager.createSession(for: makeServer(name: "First"))!
        let second = manager.createSession(for: makeServer(name: "Second"))!

        manager.switchTo(sessionID: first.id)
        manager.returnToServerList()

        XCTAssertNil(manager.activeSessionID)
        XCTAssertEqual(manager.sessions.map(\.id), [first.id, second.id])
    }

    func testSwitchToPreviousTogglesTopTwoSessions() {
        let manager = SessionManager()
        let first = manager.createSession(for: makeServer(name: "First"))!
        let second = manager.createSession(for: makeServer(name: "Second"))!

        // sessions[0] = Second (most recent), sessions[1] = First
        manager.switchTo(sessionID: second.id)
        XCTAssertEqual(manager.activeSessionID, second.id)

        // Toggle to previous (First)
        manager.switchToPrevious()
        XCTAssertEqual(manager.activeSessionID, first.id)
        XCTAssertEqual(manager.sessions[0].id, first.id)
        XCTAssertEqual(manager.sessions[1].id, second.id)

        // Toggle again — back to Second
        manager.switchToPrevious()
        XCTAssertEqual(manager.activeSessionID, second.id)
        XCTAssertEqual(manager.sessions[0].id, second.id)
        XCTAssertEqual(manager.sessions[1].id, first.id)
    }

    func testSwitchToPreviousNoOpWithSingleSession() {
        let manager = SessionManager()
        let only = manager.createSession(for: makeServer(name: "Only"))!

        manager.switchTo(sessionID: only.id)
        manager.switchToPrevious()

        XCTAssertEqual(manager.activeSessionID, only.id)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    private func makeServer(name: String) -> Server {
        Server(name: name, hostname: "\(name.lowercased()).example.com", username: "user")
    }
}
