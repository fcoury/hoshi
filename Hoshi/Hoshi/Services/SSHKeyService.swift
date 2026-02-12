import Foundation
import CryptoKit
import Crypto

// SSH key types supported by the app
enum SSHKeyType: String, CaseIterable {
    case ed25519 = "Ed25519"
    case rsa = "RSA"
}

// Represents a generated SSH key pair
struct SSHKeyPair {
    let privateKeyPEM: Data
    let publicKeyAuthorized: String
    let keyType: SSHKeyType
    let tag: String
}

// Generates and manages SSH key pairs
final class SSHKeyService {

    static let shared = SSHKeyService()

    private let keychain = KeychainService.shared

    private init() {}

    // Generate a new SSH key pair and store it in the Keychain
    func generateKeyPair(type: SSHKeyType, tag: String) throws -> SSHKeyPair {
        switch type {
        case .ed25519:
            return try generateEd25519KeyPair(tag: tag)
        case .rsa:
            return try generateRSAKeyPair(tag: tag)
        }
    }

    // Retrieve a stored key pair's public key in authorized_keys format
    func publicKey(forTag tag: String, type: SSHKeyType) throws -> String? {
        guard let keyData = try keychain.retrievePrivateKey(withTag: tag) else {
            return nil
        }

        switch type {
        case .ed25519:
            return try ed25519PublicKeyString(from: keyData)
        case .rsa:
            return try rsaPublicKeyString(from: keyData)
        }
    }

    // List all stored key tags
    func listKeys() -> [String] {
        keychain.listKeyTags()
    }

    // Delete a key pair
    func deleteKey(tag: String) {
        keychain.deletePrivateKey(withTag: tag)
    }

    // MARK: - Ed25519

    private func generateEd25519KeyPair(tag: String) throws -> SSHKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Encode the private key raw representation for Keychain storage
        let privateKeyData = privateKey.rawRepresentation

        // Store in Keychain
        try keychain.storePrivateKey(privateKeyData, withTag: tag)

        // Build the authorized_keys format: "ssh-ed25519 <base64-encoded-key> <tag>"
        let publicKeyString = formatEd25519AuthorizedKey(publicKey: publicKey, comment: tag)

        return SSHKeyPair(
            privateKeyPEM: privateKeyData,
            publicKeyAuthorized: publicKeyString,
            keyType: .ed25519,
            tag: tag
        )
    }

    private func formatEd25519AuthorizedKey(publicKey: Curve25519.Signing.PublicKey, comment: String) -> String {
        // SSH wire format: string "ssh-ed25519" + string <32-byte-key>
        var wireFormat = Data()

        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!
        wireFormat.append(contentsOf: withUnsafeBytes(of: UInt32(keyTypeData.count).bigEndian) { Array($0) })
        wireFormat.append(keyTypeData)

        let rawKey = publicKey.rawRepresentation
        wireFormat.append(contentsOf: withUnsafeBytes(of: UInt32(rawKey.count).bigEndian) { Array($0) })
        wireFormat.append(rawKey)

        let base64Key = wireFormat.base64EncodedString()
        return "ssh-ed25519 \(base64Key) \(comment)"
    }

    private func ed25519PublicKeyString(from privateKeyData: Data) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        return formatEd25519AuthorizedKey(publicKey: privateKey.publicKey, comment: "hoshi-key")
    }

    // MARK: - RSA

    private func generateRSAKeyPair(tag: String) throws -> SSHKeyPair {
        // Use the Security framework for RSA key generation
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 4096,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SSHConnectionError.keyGenerationFailed(reason: message)
        }

        // Export the private key
        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SSHConnectionError.keyGenerationFailed(reason: message)
        }

        // Store in Keychain
        try keychain.storePrivateKey(privateKeyData, withTag: tag)

        // Extract the public key
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Failed to extract public key")
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SSHConnectionError.keyGenerationFailed(reason: message)
        }

        let publicKeyString = formatRSAAuthorizedKey(publicKeyData: publicKeyData, comment: tag)

        return SSHKeyPair(
            privateKeyPEM: privateKeyData,
            publicKeyAuthorized: publicKeyString,
            keyType: .rsa,
            tag: tag
        )
    }

    private func formatRSAAuthorizedKey(publicKeyData: Data, comment: String) -> String {
        // For RSA, the public key data from SecKeyCopyExternalRepresentation is in PKCS#1 format
        // SSH wire format: string "ssh-rsa" + mpint e + mpint n
        // We need to parse the PKCS#1 DER to extract e and n

        // Simple approach: wrap the raw key data in SSH wire format
        var wireFormat = Data()

        let keyType = "ssh-rsa"
        let keyTypeData = keyType.data(using: .utf8)!
        wireFormat.append(contentsOf: withUnsafeBytes(of: UInt32(keyTypeData.count).bigEndian) { Array($0) })
        wireFormat.append(keyTypeData)

        // Parse PKCS#1 RSAPublicKey to extract e and n
        // DER: SEQUENCE { INTEGER n, INTEGER e }
        if let (n, e) = parsePKCS1PublicKey(publicKeyData) {
            // Write e
            wireFormat.append(contentsOf: withUnsafeBytes(of: UInt32(e.count).bigEndian) { Array($0) })
            wireFormat.append(e)

            // Write n
            wireFormat.append(contentsOf: withUnsafeBytes(of: UInt32(n.count).bigEndian) { Array($0) })
            wireFormat.append(n)
        }

        let base64Key = wireFormat.base64EncodedString()
        return "ssh-rsa \(base64Key) \(comment)"
    }

    // Parse a PKCS#1 RSAPublicKey DER structure to extract n and e
    private func parsePKCS1PublicKey(_ data: Data) -> (n: Data, e: Data)? {
        var index = 0
        let bytes = [UInt8](data)

        // SEQUENCE tag
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1

        // Skip length
        index = skipDERLength(bytes: bytes, index: index)

        // First INTEGER: n (modulus)
        guard let n = readDERInteger(bytes: bytes, index: &index) else { return nil }

        // Second INTEGER: e (exponent)
        guard let e = readDERInteger(bytes: bytes, index: &index) else { return nil }

        return (n, e)
    }

    private func skipDERLength(bytes: [UInt8], index: Int) -> Int {
        var i = index
        guard i < bytes.count else { return i }

        if bytes[i] & 0x80 == 0 {
            return i + 1
        }

        let lengthBytes = Int(bytes[i] & 0x7F)
        return i + 1 + lengthBytes
    }

    private func readDERInteger(bytes: [UInt8], index: inout Int) -> Data? {
        guard index < bytes.count, bytes[index] == 0x02 else { return nil }
        index += 1

        // Read length
        var length = 0
        if bytes[index] & 0x80 == 0 {
            length = Int(bytes[index])
            index += 1
        } else {
            let lengthBytes = Int(bytes[index] & 0x7F)
            index += 1
            for _ in 0..<lengthBytes {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }

        guard index + length <= bytes.count else { return nil }
        let data = Data(bytes[index..<(index + length)])
        index += length
        return data
    }

    // RSA components extracted from a PKCS#1 DER private key
    struct RSAComponents {
        let n: [UInt8]  // modulus
        let e: [UInt8]  // public exponent
        let d: [UInt8]  // private exponent
    }

    // Parse a PKCS#1 RSAPrivateKey DER structure to extract n, e, d
    // DER layout: SEQUENCE { INTEGER version, INTEGER n, INTEGER e, INTEGER d, ... }
    static func parseRSAPrivateKeyDER(_ data: Data) throws -> RSAComponents {
        var index = 0
        let bytes = [UInt8](data)

        // Outer SEQUENCE tag
        guard index < bytes.count, bytes[index] == 0x30 else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Invalid RSA key: missing SEQUENCE")
        }
        index += 1
        index = skipDERLengthStatic(bytes: bytes, index: index)

        // version INTEGER (skip it)
        guard let _ = readDERIntegerStatic(bytes: bytes, index: &index) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Invalid RSA key: missing version")
        }

        // n (modulus)
        guard let nData = readDERIntegerStatic(bytes: bytes, index: &index) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Invalid RSA key: missing modulus")
        }

        // e (public exponent)
        guard let eData = readDERIntegerStatic(bytes: bytes, index: &index) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Invalid RSA key: missing public exponent")
        }

        // d (private exponent)
        guard let dData = readDERIntegerStatic(bytes: bytes, index: &index) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Invalid RSA key: missing private exponent")
        }

        // Strip leading zero bytes (DER uses them for positive sign, BIGNUMs don't need them)
        func stripLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
            var result = bytes
            while result.count > 1 && result[0] == 0 {
                result.removeFirst()
            }
            return result
        }

        return RSAComponents(
            n: stripLeadingZeros([UInt8](nData)),
            e: stripLeadingZeros([UInt8](eData)),
            d: stripLeadingZeros([UInt8](dData))
        )
    }

    // Static versions of the DER parsing helpers for use from SSHService
    private static func skipDERLengthStatic(bytes: [UInt8], index: Int) -> Int {
        var i = index
        guard i < bytes.count else { return i }

        if bytes[i] & 0x80 == 0 {
            return i + 1
        }

        let lengthBytes = Int(bytes[i] & 0x7F)
        return i + 1 + lengthBytes
    }

    private static func readDERIntegerStatic(bytes: [UInt8], index: inout Int) -> Data? {
        guard index < bytes.count, bytes[index] == 0x02 else { return nil }
        index += 1

        var length = 0
        if bytes[index] & 0x80 == 0 {
            length = Int(bytes[index])
            index += 1
        } else {
            let lengthBytes = Int(bytes[index] & 0x7F)
            index += 1
            for _ in 0..<lengthBytes {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }

        guard index + length <= bytes.count else { return nil }
        let data = Data(bytes[index..<(index + length)])
        index += length
        return data
    }

    private func rsaPublicKeyString(from privateKeyData: Data) throws -> String {
        // Reconstruct SecKey from raw data
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &error) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Failed to reconstruct private key")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Failed to extract public key")
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SSHConnectionError.keyGenerationFailed(reason: "Failed to export public key")
        }

        return formatRSAAuthorizedKey(publicKeyData: publicKeyData, comment: "hoshi-key")
    }
}
