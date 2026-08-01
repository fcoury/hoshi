import XCTest
import SwiftData
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
        XCTAssertNil(server.keyID)
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

    func testServerEndpointNeverGroupsPortDigits() {
        let server = Server(
            name: "Local",
            hostname: "localhost",
            port: 2222,
            username: "felipe.coury"
        )

        XCTAssertEqual(2222.formatted(.number.locale(Locale(identifier: "pt_BR"))), "2.222")
        XCTAssertEqual(server.endpoint, "localhost:2222")
        XCTAssertEqual(server.loginEndpoint, "felipe.coury@localhost:2222")
    }

    func testServerEndpointPreservesFiveDigitPortsWithoutGrouping() {
        let server = Server(
            name: "Remote",
            hostname: "server.example",
            port: 65_535,
            username: "deploy"
        )

        XCTAssertEqual(server.endpoint, "server.example:65535")
        XCTAssertEqual(server.loginEndpoint, "deploy@server.example:65535")
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

    func testServerRetainsSelectedSSHKey() {
        let server = Server(
            name: "Key Server",
            hostname: "example.com",
            username: "user",
            authMethod: .key,
            keyID: "deploy-key"
        )

        XCTAssertEqual(server.keyID, "deploy-key")
    }

    @MainActor
    func testServerPersistsSelectedSSHKey() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Server.self, configurations: configuration)
        let context = ModelContext(container)
        let server = Server(
            name: "Persisted Key Server",
            hostname: "example.com",
            username: "user",
            authMethod: .key,
            keyID: "persisted-deploy-key"
        )

        context.insert(server)
        try context.save()

        let savedServers = try context.fetch(FetchDescriptor<Server>())
        XCTAssertEqual(savedServers.first?.keyID, "persisted-deploy-key")
    }
}
