import XCTest
@testable import Hoshi

final class KeychainServiceTests: XCTestCase {
    let keychain = KeychainService.shared
    let testServerID = UUID()

    override func tearDownWithError() throws {
        try keychain.deletePassword(forServer: testServerID)
        try keychain.deletePrivateKey(withTag: "test-key")
        try super.tearDownWithError()
    }

    func testStoreAndRetrievePassword() throws {
        let password = "test-password-123"
        try keychain.storePassword(password, forServer: testServerID)

        let retrieved = try keychain.retrievePassword(forServer: testServerID)
        XCTAssertEqual(retrieved, password)
    }

    func testRetrieveNonexistentPassword() throws {
        let retrieved = try keychain.retrievePassword(forServer: UUID())
        XCTAssertNil(retrieved)
    }

    func testDeletePassword() throws {
        let password = "to-be-deleted"
        try keychain.storePassword(password, forServer: testServerID)

        try keychain.deletePassword(forServer: testServerID)

        let retrieved = try keychain.retrievePassword(forServer: testServerID)
        XCTAssertNil(retrieved)
    }

    func testOverwritePassword() throws {
        try keychain.storePassword("old-password", forServer: testServerID)
        try keychain.storePassword("new-password", forServer: testServerID)

        let retrieved = try keychain.retrievePassword(forServer: testServerID)
        XCTAssertEqual(retrieved, "new-password")
    }

    func testStoreAndRetrievePrivateKey() throws {
        let keyData = Data(repeating: 0x42, count: 32)
        try keychain.storePrivateKey(keyData, withTag: "test-key")

        let retrieved = try keychain.retrievePrivateKey(withTag: "test-key")
        XCTAssertEqual(retrieved, keyData)
    }

    func testRetrieveNonexistentKey() throws {
        let retrieved = try keychain.retrievePrivateKey(withTag: "nonexistent")
        XCTAssertNil(retrieved)
    }

    func testDeletingMissingCredentialsIsSafe() throws {
        try keychain.deletePassword(forServer: UUID())
        try keychain.deletePrivateKey(withTag: "missing-\(UUID().uuidString)")
    }
}
