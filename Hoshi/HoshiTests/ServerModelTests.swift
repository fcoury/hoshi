import XCTest
@testable import Hoshi

final class ServerModelTests: XCTestCase {

    func testServerDefaultValues() {
        let server = Server(
            name: "Test Server",
            hostname: "example.com",
            username: "user"
        )

        XCTAssertEqual(server.name, "Test Server")
        XCTAssertEqual(server.hostname, "example.com")
        XCTAssertEqual(server.port, 22)
        XCTAssertEqual(server.username, "user")
        XCTAssertEqual(server.authMethod, .password)
        XCTAssertFalse(server.useMosh)
        XCTAssertNil(server.lastConnected)
        XCTAssertNil(server.tmuxSession)
        XCTAssertNotNil(server.id)
    }

    func testServerCustomPort() {
        let server = Server(
            name: "Custom Port",
            hostname: "192.168.1.100",
            port: 2222,
            username: "admin",
            authMethod: .key
        )

        XCTAssertEqual(server.port, 2222)
        XCTAssertEqual(server.authMethod, .key)
    }

    func testAuthMethodCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let password = AuthMethod.password
        let key = AuthMethod.key

        let passwordData = try encoder.encode(password)
        let keyData = try encoder.encode(key)

        let decodedPassword = try decoder.decode(AuthMethod.self, from: passwordData)
        let decodedKey = try decoder.decode(AuthMethod.self, from: keyData)

        XCTAssertEqual(decodedPassword, .password)
        XCTAssertEqual(decodedKey, .key)
    }
}
