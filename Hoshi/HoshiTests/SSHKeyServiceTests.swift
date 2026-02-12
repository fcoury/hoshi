import XCTest
@testable import Hoshi

final class SSHKeyServiceTests: XCTestCase {
    let keyService = SSHKeyService.shared

    override func tearDown() {
        super.tearDown()
        keyService.deleteKey(tag: "test-ed25519")
        keyService.deleteKey(tag: "test-rsa")
    }

    func testGenerateEd25519KeyPair() throws {
        let keyPair = try keyService.generateKeyPair(type: .ed25519, tag: "test-ed25519")

        XCTAssertEqual(keyPair.keyType, .ed25519)
        XCTAssertEqual(keyPair.tag, "test-ed25519")
        XCTAssertTrue(keyPair.publicKeyAuthorized.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(keyPair.publicKeyAuthorized.hasSuffix(" test-ed25519"))
        XCTAssertFalse(keyPair.privateKeyPEM.isEmpty)
    }

    func testGenerateRSAKeyPair() throws {
        let keyPair = try keyService.generateKeyPair(type: .rsa, tag: "test-rsa")

        XCTAssertEqual(keyPair.keyType, .rsa)
        XCTAssertEqual(keyPair.tag, "test-rsa")
        XCTAssertTrue(keyPair.publicKeyAuthorized.hasPrefix("ssh-rsa "))
        XCTAssertFalse(keyPair.privateKeyPEM.isEmpty)
    }

    func testListKeys() throws {
        // Generate a key
        _ = try keyService.generateKeyPair(type: .ed25519, tag: "test-ed25519")

        let keys = keyService.listKeys()
        XCTAssertTrue(keys.contains("test-ed25519"))
    }

    func testDeleteKey() throws {
        _ = try keyService.generateKeyPair(type: .ed25519, tag: "test-ed25519")
        keyService.deleteKey(tag: "test-ed25519")

        let keys = keyService.listKeys()
        XCTAssertFalse(keys.contains("test-ed25519"))
    }

    func testEd25519PublicKeyFormat() throws {
        let keyPair = try keyService.generateKeyPair(type: .ed25519, tag: "test-ed25519")

        // The authorized_keys format has 3 parts: type base64 comment
        let parts = keyPair.publicKeyAuthorized.split(separator: " ")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")

        // base64 part should be decodable
        let base64 = String(parts[1])
        XCTAssertNotNil(Data(base64Encoded: base64))
    }
}
