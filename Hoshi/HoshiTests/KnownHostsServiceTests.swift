import XCTest
import NIOCore
import NIOPosix
import NIOSSH
@testable import Hoshi

final class KnownHostsServiceTests: XCTestCase {
    private let hostname = "known-host-\(UUID().uuidString).example.com"
    private let port = 2222
    private let algorithm = "ssh-ed25519"
    private let knownHosts = KnownHostsService()
    private var generatedKeyTags: [String] = []

    override func tearDownWithError() throws {
        try KeychainService.shared.deleteKnownHostKey(
            hostname: hostname,
            port: port,
            algorithm: algorithm
        )
        try KeychainService.shared.deleteKnownHostKey(
            hostname: hostname,
            port: port + 1,
            algorithm: algorithm
        )
        try KeychainService.shared.deleteKnownHostKey(
            hostname: hostname,
            port: port,
            algorithm: "ecdsa-sha2-nistp256"
        )
        for tag in generatedKeyTags {
            try SSHKeyService.shared.deleteKey(tag: tag)
        }
        try super.tearDownWithError()
    }

    func testFingerprintUsesOpenSSHSHA256Format() {
        let identity = makeIdentity(keyData: Data("known-host-key".utf8))

        XCTAssertEqual(
            identity.fingerprint,
            "SHA256:1Gwev91QTX7CK5pxSd2E2GuZ+hUlsbhZYZJDY2OJtrk"
        )
    }

    func testUnknownHostRequiresTrust() throws {
        XCTAssertEqual(try knownHosts.status(for: makeIdentity()), .unknown)
    }

    func testTrustedHostPersistsAcrossServiceInstances() throws {
        let identity = makeIdentity()
        try knownHosts.trust(identity)

        XCTAssertEqual(try KnownHostsService().status(for: identity), .trusted)
    }

    func testChangedHostKeyIsRejectedWithoutReplacingTrustedKey() throws {
        let original = makeIdentity(keyData: Data("original-key".utf8))
        let changed = makeIdentity(keyData: Data("changed-key".utf8))
        try knownHosts.trust(original)

        XCTAssertEqual(
            try knownHosts.status(for: changed),
            .changed(
                expectedFingerprint: original.fingerprint,
                presentedFingerprint: changed.fingerprint
            )
        )
        XCTAssertThrowsError(try knownHosts.trust(changed))
        XCTAssertEqual(try knownHosts.status(for: original), .trusted)
    }

    func testHostKeysAreIsolatedByPort() throws {
        let original = makeIdentity()
        let otherPort = makeIdentity(port: port + 1)
        try knownHosts.trust(original)

        XCTAssertEqual(try knownHosts.status(for: otherPort), .unknown)
    }

    func testHostKeysAreIsolatedByAlgorithm() throws {
        let original = makeIdentity()
        let otherAlgorithm = makeIdentity(algorithm: "ecdsa-sha2-nistp256")
        try knownHosts.trust(original)

        XCTAssertEqual(try knownHosts.status(for: otherAlgorithm), .unknown)
    }

    func testHostnamesAreMatchedCaseInsensitively() throws {
        let original = makeIdentity()
        let uppercase = makeIdentity(hostname: hostname.uppercased())
        try knownHosts.trust(original)

        XCTAssertEqual(try knownHosts.status(for: uppercase), .trusted)
    }

    func testRemovingTrustedHostRequiresTrustAgain() throws {
        let identity = makeIdentity()
        try knownHosts.trust(identity)
        try knownHosts.remove(identity)

        XCTAssertEqual(try knownHosts.status(for: identity), .unknown)
    }

    func testForgettingHostKeysClearsEveryAlgorithmForThatPortOnly() throws {
        let ed25519 = makeIdentity()
        let ecdsa = makeIdentity(algorithm: "ecdsa-sha2-nistp256")
        let otherPort = makeIdentity(port: port + 1)
        try knownHosts.trust(ed25519)
        try knownHosts.trust(ecdsa)
        try knownHosts.trust(otherPort)

        try knownHosts.forgetHostKeys(hostname: hostname, port: port)

        XCTAssertEqual(try knownHosts.status(for: ed25519), .unknown)
        XCTAssertEqual(try knownHosts.status(for: ecdsa), .unknown)
        XCTAssertEqual(try knownHosts.status(for: otherPort), .trusted)
    }

    func testHostKeyChangeIsFoundDirectlyAndInsideFallbackErrors() {
        let changed = SSHHostKeyTrustError.changed(
            hostname: hostname,
            port: port,
            expectedFingerprint: "SHA256:old",
            presentedFingerprint: "SHA256:new"
        )

        let direct = HostKeyChange(in: changed)
        XCTAssertEqual(direct?.endpoint, "\(hostname):\(port)")
        XCTAssertEqual(direct?.presentedFingerprint, "SHA256:new")

        let wrapped = ConnectionFallbackError(moshError: URLError(.timedOut), sshError: changed)
        XCTAssertEqual(HostKeyChange(in: wrapped), direct)
        XCTAssertEqual(ErrorPresentation.classify(wrapped).hostKeyChange, direct)
        XCTAssertNil(HostKeyChange(in: SSHHostKeyTrustError.declined(hostname: hostname, port: port)))
    }

    func testKnownHostAccountsParseFromTheRightSoIPv6HostsSurvive() {
        let plain = KnownHostsService.parseAccount("hostkey-example.com:22:ssh-ed25519")
        XCTAssertEqual(plain?.hostname, "example.com")
        XCTAssertEqual(plain?.port, 22)
        XCTAssertEqual(plain?.algorithm, "ssh-ed25519")

        let ipv6 = KnownHostsService.parseAccount("hostkey-fe80::1:2222:ecdsa-sha2-nistp256")
        XCTAssertEqual(ipv6?.hostname, "fe80::1")
        XCTAssertEqual(ipv6?.port, 2222)

        XCTAssertNil(KnownHostsService.parseAccount("sshkey-mine"))
        XCTAssertNil(KnownHostsService.parseAccount("hostkey-example.com:notaport:ssh-rsa"))
    }

    func testTrustedHostKeysListsStoredIdentities() throws {
        let identity = makeIdentity()
        try knownHosts.trust(identity)

        // Keychain accounts store hostnames lowercased, matching case-insensitive lookups.
        let listed = try knownHosts.trustedHostKeys().first { $0.identity.hostname == hostname.lowercased() }
        XCTAssertEqual(listed?.identity.port, port)
        XCTAssertEqual(listed?.identity.algorithm, algorithm)
        XCTAssertEqual(listed?.identity.fingerprint, identity.fingerprint)
    }

    func testVerificationCommandNamesTheMatchingHostKeyFile() {
        XCTAssertEqual(
            HostKeyVerification.verificationCommand(for: "ssh-ed25519"),
            "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
        )
        XCTAssertEqual(HostKeyVerification.hostKeyFile(for: "ecdsa-sha2-nistp256"), "ssh_host_ecdsa_key.pub")
        XCTAssertEqual(HostKeyVerification.hostKeyFile(for: "rsa-sha2-512"), "ssh_host_rsa_key.pub")
    }

    func testValidatorRejectsUnknownHostBeforeUserTrust() throws {
        let hostKey = try makeHostKey()
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let promise = eventLoopGroup.next().makePromise(of: Void.self)

        knownHosts.validator(hostname: hostname, port: port)
            .validateHostKey(hostKey: hostKey, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            guard let trustError = error as? SSHHostKeyTrustError,
                  case .untrusted(let identity) = trustError else {
                XCTFail("Expected an untrusted-host error, got \(error)")
                return
            }
            XCTAssertEqual(identity.hostname, self.hostname)
            XCTAssertEqual(identity.port, self.port)
        }
    }

    func testValidatorAcceptsTrustedHost() throws {
        let hostKey = try makeHostKey()
        let identity = try SSHHostKeyIdentity(hostname: hostname, port: port, hostKey: hostKey)
        try knownHosts.trust(identity)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let promise = eventLoopGroup.next().makePromise(of: Void.self)

        knownHosts.validator(hostname: hostname, port: port)
            .validateHostKey(hostKey: hostKey, validationCompletePromise: promise)

        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testValidatorRejectsChangedHostKey() throws {
        let trustedHostKey = try makeHostKey()
        let changedHostKey = try makeHostKey()
        let trustedIdentity = try SSHHostKeyIdentity(
            hostname: hostname,
            port: port,
            hostKey: trustedHostKey
        )
        let changedIdentity = try SSHHostKeyIdentity(
            hostname: hostname,
            port: port,
            hostKey: changedHostKey
        )
        try knownHosts.trust(trustedIdentity)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let promise = eventLoopGroup.next().makePromise(of: Void.self)

        knownHosts.validator(hostname: hostname, port: port)
            .validateHostKey(hostKey: changedHostKey, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            guard let trustError = error as? SSHHostKeyTrustError,
                  case .changed(_, _, let expected, let presented) = trustError else {
                XCTFail("Expected a changed-host-key error, got \(error)")
                return
            }
            XCTAssertEqual(expected, trustedIdentity.fingerprint)
            XCTAssertEqual(presented, changedIdentity.fingerprint)
        }
    }

    private func makeIdentity(
        hostname: String? = nil,
        port: Int? = nil,
        algorithm: String? = nil,
        keyData: Data = Data("known-host-key".utf8)
    ) -> SSHHostKeyIdentity {
        SSHHostKeyIdentity(
            hostname: hostname ?? self.hostname,
            port: port ?? self.port,
            algorithm: algorithm ?? self.algorithm,
            publicKeyData: keyData
        )
    }

    private func makeHostKey() throws -> NIOSSHPublicKey {
        let tag = "known-host-validator-\(UUID().uuidString)"
        let keyPair = try SSHKeyService.shared.generateKeyPair(type: .ed25519, tag: tag)
        generatedKeyTags.append(tag)
        return try NIOSSHPublicKey(openSSHPublicKey: keyPair.publicKeyAuthorized)
    }
}
