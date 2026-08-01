import Foundation
import Citadel
import CryptoKit
import NIOCore
import NIOSSH

// The negotiated SSH public key and the standard SHA-256 fingerprint shown to users.
struct SSHHostKeyIdentity: Equatable, Sendable {
    let hostname: String
    let port: Int
    let algorithm: String
    let publicKeyData: Data

    init(hostname: String, port: Int, algorithm: String, publicKeyData: Data) {
        self.hostname = hostname
        self.port = port
        self.algorithm = algorithm
        self.publicKeyData = publicKeyData
    }

    init(hostname: String, port: Int, hostKey: NIOSSHPublicKey) throws {
        let representation = String(openSSHPublicKey: hostKey)
        let components = representation.split(separator: " ", maxSplits: 2)
        guard components.count >= 2,
              let publicKeyData = Data(base64Encoded: String(components[1])) else {
            throw SSHHostKeyTrustError.invalidHostKey(hostname: hostname, port: port)
        }

        self.init(
            hostname: hostname,
            port: port,
            algorithm: String(components[0]),
            publicKeyData: publicKeyData
        )
    }

    var openSSHRepresentation: String {
        "\(algorithm) \(publicKeyData.base64EncodedString())"
    }

    var fingerprint: String {
        let digest = SHA256.hash(data: publicKeyData)
        let encodedDigest = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(encodedDigest)"
    }

    var endpoint: String {
        "\(hostname):\(port)"
    }
}

enum KnownHostStatus: Equatable {
    case unknown
    case trusted
    case changed(expectedFingerprint: String, presentedFingerprint: String)
}

enum SSHHostKeyTrustError: LocalizedError {
    case invalidHostKey(hostname: String, port: Int)
    case invalidStoredHostKey(hostname: String, port: Int)
    case untrusted(SSHHostKeyIdentity)
    case declined(hostname: String, port: Int)
    case changed(hostname: String, port: Int, expectedFingerprint: String, presentedFingerprint: String)

    var errorDescription: String? {
        switch self {
        case .invalidHostKey(let hostname, let port):
            return "The SSH host key presented by \(hostname):\(port) is invalid."
        case .invalidStoredHostKey(let hostname, let port):
            return "The trusted SSH host key for \(hostname):\(port) could not be read."
        case .untrusted(let identity):
            return "The SSH host key for \(identity.endpoint) must be trusted before connecting."
        case .declined(let hostname, let port):
            return "The SSH host key for \(hostname):\(port) was not trusted."
        case .changed(let hostname, let port, let expected, let presented):
            return "The SSH host key for \(hostname):\(port) has changed. "
                + "Expected \(expected), but received \(presented)."
        }
    }
}

// Persist host identities in the iOS Keychain, isolated by host, port, and key algorithm.
final class KnownHostsService: @unchecked Sendable {
    static let shared = KnownHostsService()

    private let keychain: KeychainService

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain
    }

    func status(for identity: SSHHostKeyIdentity) throws -> KnownHostStatus {
        guard let trustedKey = try keychain.retrieveKnownHostKey(
            hostname: identity.hostname,
            port: identity.port,
            algorithm: identity.algorithm
        ) else {
            return .unknown
        }

        guard trustedKey != identity.openSSHRepresentation else {
            return .trusted
        }

        let components = trustedKey.split(separator: " ", maxSplits: 2)
        guard components.count >= 2,
              let trustedData = Data(base64Encoded: String(components[1])) else {
            throw SSHHostKeyTrustError.invalidStoredHostKey(
                hostname: identity.hostname,
                port: identity.port
            )
        }

        let trustedIdentity = SSHHostKeyIdentity(
            hostname: identity.hostname,
            port: identity.port,
            algorithm: String(components[0]),
            publicKeyData: trustedData
        )
        return .changed(
            expectedFingerprint: trustedIdentity.fingerprint,
            presentedFingerprint: identity.fingerprint
        )
    }

    func trust(_ identity: SSHHostKeyIdentity) throws {
        switch try status(for: identity) {
        case .trusted:
            return
        case .unknown:
            try keychain.storeKnownHostKey(
                identity.openSSHRepresentation,
                hostname: identity.hostname,
                port: identity.port,
                algorithm: identity.algorithm
            )
        case .changed(let expected, let presented):
            throw SSHHostKeyTrustError.changed(
                hostname: identity.hostname,
                port: identity.port,
                expectedFingerprint: expected,
                presentedFingerprint: presented
            )
        }
    }

    func remove(_ identity: SSHHostKeyIdentity) throws {
        try keychain.deleteKnownHostKey(
            hostname: identity.hostname,
            port: identity.port,
            algorithm: identity.algorithm
        )
    }

    func validator(hostname: String, port: Int) -> SSHHostKeyValidator {
        .custom(SSHKnownHostValidator(hostname: hostname, port: port, knownHosts: self))
    }
}

// Queue first-use prompts so concurrent connection attempts cannot overwrite one another.
@MainActor
@Observable
final class HostKeyTrustCoordinator {
    static let shared = HostKeyTrustCoordinator()

    private(set) var pendingIdentity: SSHHostKeyIdentity?

    @ObservationIgnored
    private var pendingRequests: [(identity: SSHHostKeyIdentity, continuation: CheckedContinuation<Bool, Never>)] = []

    private init() {}

    func requestTrust(for identity: SSHHostKeyIdentity) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingRequests.append((identity: identity, continuation: continuation))
            if pendingIdentity == nil {
                pendingIdentity = identity
            }
        }
    }

    func resolvePendingIdentity(trusted: Bool) {
        guard !pendingRequests.isEmpty else { return }
        let request = pendingRequests.removeFirst()
        pendingIdentity = nil
        request.continuation.resume(returning: trusted)

        if let nextIdentity = pendingRequests.first?.identity {
            Task { @MainActor [weak self] in
                self?.pendingIdentity = nextIdentity
            }
        }
    }
}

// Bridge Citadel's event-loop validation callback to the on-screen trust prompt.
private final class SSHKnownHostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostname: String
    private let port: Int
    private let knownHosts: KnownHostsService

    init(hostname: String, port: Int, knownHosts: KnownHostsService) {
        self.hostname = hostname
        self.port = port
        self.knownHosts = knownHosts
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let identity = try SSHHostKeyIdentity(hostname: hostname, port: port, hostKey: hostKey)
            switch try knownHosts.status(for: identity) {
            case .trusted:
                validationCompletePromise.succeed(())
            case .changed(let expected, let presented):
                validationCompletePromise.fail(
                    SSHHostKeyTrustError.changed(
                        hostname: hostname,
                        port: port,
                        expectedFingerprint: expected,
                        presentedFingerprint: presented
                    )
                )
            case .unknown:
                // Citadel's handshake has a fixed 10-second login timeout, so user
                // confirmation must happen between attempts rather than holding this promise.
                validationCompletePromise.fail(SSHHostKeyTrustError.untrusted(identity))
            }
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
