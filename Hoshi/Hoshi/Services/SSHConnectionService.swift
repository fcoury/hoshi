import Foundation
import Citadel
import Crypto
import NIOSSH
@preconcurrency import CCryptoBoringSSL

/// Shared authentication and verified-host bootstrap for every terminal transport.
@MainActor
enum SSHConnectionService {
    static func connect(
        server: Server,
        password: String?,
        privateKeyTag: String?
    ) async throws -> SSHClient {
        try Task.checkCancellation()

        let authentication = try authenticationMethod(
            server: server,
            password: password,
            privateKeyTag: privateKeyTag
        )

        let client = try await SSHClient.connect(
            host: server.hostname,
            port: server.port,
            authenticationMethod: authentication,
            hostKeyValidator: KnownHostsService.shared.validator(
                hostname: server.hostname,
                port: server.port
            ),
            reconnect: .never
        )

        if Task.isCancelled {
            try? await client.close()
            throw CancellationError()
        }

        return client
    }

    static func authenticationMethod(
        server: Server,
        password: String?,
        privateKeyTag: String?
    ) throws -> SSHAuthenticationMethod {
        switch server.authMethod {
        case .password:
            guard let password else {
                throw SSHConnectionError.passwordNotFound
            }
            return .passwordBased(username: server.username, password: password)

        case .key:
            guard let privateKeyTag,
                  let keyData = try KeychainService.shared.retrievePrivateKey(withTag: privateKeyTag) else {
                throw SSHConnectionError.keyNotFound
            }

            if keyData.count == 32 {
                let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
                return .ed25519(username: server.username, privateKey: privateKey)
            }

            let components = try SSHKeyService.parseRSAPrivateKeyDER(keyData)
            guard let modulus = CCryptoBoringSSL_BN_bin2bn(components.n, components.n.count, nil),
                  let publicExponent = CCryptoBoringSSL_BN_bin2bn(components.e, components.e.count, nil),
                  let privateExponent = CCryptoBoringSSL_BN_bin2bn(components.d, components.d.count, nil) else {
                throw SSHConnectionError.keyNotFound
            }

            let rsaKey = Insecure.RSA.PrivateKey(
                privateExponent: privateExponent,
                publicExponent: publicExponent,
                modulus: modulus
            )
            return .rsa(username: server.username, privateKey: rsaKey)
        }
    }
}
