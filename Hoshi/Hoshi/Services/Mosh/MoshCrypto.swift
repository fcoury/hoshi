import Foundation
import CryptoSwift

// Direction of a mosh datagram (encoded in the nonce)
enum MoshDirection: UInt8 {
    case toServer = 0
    case toClient = 1
}

// 12-byte nonce for AES-128-OCB3
// Format: 4 zero bytes + 8 bytes (direction bit in high bit of byte 4, sequence in lower 63 bits)
struct MoshNonce {
    static let length = 12
    // The last 8 bytes sent on the wire (the "cc_str" in mosh C++)
    static let wireLength = 8

    let bytes: [UInt8]

    // Construct a nonce from a direction and sequence number
    init(direction: MoshDirection, sequenceNumber: UInt64) {
        var nonce = [UInt8](repeating: 0, count: MoshNonce.length)
        // Bytes 0-3: always zero
        // Bytes 4-11: direction bit (high bit) | sequence number (lower 63 bits)
        var value = sequenceNumber & 0x7FFFFFFFFFFFFFFF
        if direction == .toClient {
            value |= (1 << 63)
        }
        // Store as big-endian
        for i in 0..<8 {
            nonce[4 + i] = UInt8((value >> (56 - i * 8)) & 0xFF)
        }
        self.bytes = nonce
    }

    // Reconstruct a nonce from the 8-byte wire representation.
    // Wire bytes already include the direction bit (MSB of the first byte).
    init(wireBytes: [UInt8], direction: MoshDirection) {
        precondition(wireBytes.count == MoshNonce.wireLength)
        var nonce = [UInt8](repeating: 0, count: MoshNonce.length)
        // First 4 bytes are zero, last 8 are the wire bytes
        for i in 0..<8 {
            nonce[4 + i] = wireBytes[i]
        }
        _ = direction
        self.bytes = nonce
    }

    // The 8-byte wire representation (bytes 4-11 of the full nonce)
    var wireBytes: [UInt8] {
        Array(bytes[4..<12])
    }

    // Extract the sequence number from the nonce
    var sequenceNumber: UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[4 + i])
        }
        return value & 0x7FFFFFFFFFFFFFFF
    }
}

// Handles AES-128-OCB3 encryption and decryption for mosh datagrams
final class MoshCryptoSession {
    private let key: [UInt8]
    // OCB tag length in bytes
    static let tagLength = 16

    init(key: Data) throws {
        guard key.count == 16 else {
            throw MoshCryptoError.invalidKeyLength(key.count)
        }
        self.key = Array(key)
    }

    // Encrypt plaintext into a wire datagram
    // Wire format: nonce_cc (8 bytes) + ciphertext + tag (16 bytes)
    func encrypt(plaintext: Data, nonce: MoshNonce) throws -> Data {
        let ocb = OCB(
            nonce: nonce.bytes,
            tagLength: MoshCryptoSession.tagLength,
            mode: .combined
        )
        let aes = try AES(key: key, blockMode: ocb, padding: .noPadding)
        let encrypted = try aes.encrypt(Array(plaintext))
        // In .combined mode this includes ciphertext + tag.
        var result = Data()
        result.append(contentsOf: nonce.wireBytes)
        result.append(contentsOf: encrypted)
        return result
    }

    // Decrypt a wire datagram
    // Input: nonce_cc (8 bytes) + ciphertext + tag (16 bytes)
    // Returns the decrypted plaintext
    func decrypt(datagram: Data, direction: MoshDirection) throws -> (plaintext: Data, sequenceNumber: UInt64) {
        guard datagram.count > MoshNonce.wireLength + MoshCryptoSession.tagLength else {
            throw MoshCryptoError.datagramTooShort
        }

        let wireBytes = Array(datagram[0..<MoshNonce.wireLength])
        let cipherAndTag = Array(datagram[MoshNonce.wireLength...])

        let nonce = MoshNonce(wireBytes: wireBytes, direction: direction)

        let ocb = OCB(
            nonce: nonce.bytes,
            tagLength: MoshCryptoSession.tagLength,
            mode: .combined
        )
        let aes = try AES(key: key, blockMode: ocb, padding: .noPadding)
        let decrypted = try aes.decrypt(cipherAndTag)

        return (plaintext: Data(decrypted), sequenceNumber: nonce.sequenceNumber)
    }
}

enum MoshCryptoError: LocalizedError {
    case invalidKeyLength(Int)
    case datagramTooShort
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let length):
            return "Invalid mosh key length: \(length) bytes (expected 16)"
        case .datagramTooShort:
            return "Received mosh datagram too short to contain valid data"
        case .decryptionFailed:
            return "Failed to decrypt mosh datagram"
        }
    }
}
