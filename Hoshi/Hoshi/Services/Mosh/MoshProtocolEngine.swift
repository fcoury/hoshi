import Foundation
import zlib

struct MoshDecodedDatagram: Sendable {
    let instruction: MoshTransportInstruction
    let outputs: [MoshHostOutput]
}

/// Owns mutable SSP framing and crypto state away from the UI/main actor.
actor MoshProtocolEngine {
    private let cryptoSession: MoshCryptoSession
    private var fragmentAssembly = MoshFragmentAssembly()
    private var fragmenter = MoshFragmenter()
    private var sendSequenceNumber: UInt64 = 0
    private var lastRemoteTimestamp: UInt16 = 0

    init(key: Data) throws {
        self.cryptoSession = try MoshCryptoSession(key: key)
    }

    func reset() {
        fragmentAssembly.reset()
        fragmenter = MoshFragmenter()
        sendSequenceNumber = 0
        lastRemoteTimestamp = 0
    }

    func discardIncompleteFragments() {
        fragmentAssembly.reset()
    }

    func decode(_ datagram: Data, direction: MoshDirection = .toClient) throws -> MoshDecodedDatagram? {
        let (plaintext, _) = try cryptoSession.decrypt(datagram: datagram, direction: direction)
        let fragment = try MoshFragment(fromPayload: depacketize(plaintext))

        guard let compressedInstruction = fragmentAssembly.addFragment(fragment) else {
            return nil
        }

        let instruction = try MoshTransportInstruction.decode(
            from: Self.decompress(compressedInstruction)
        )
        let outputs = instruction.diff.isEmpty ? [] : try MoshHostOutput.decode(from: instruction.diff)
        return MoshDecodedDatagram(instruction: instruction, outputs: outputs)
    }

    func encode(_ instruction: MoshTransportInstruction) throws -> [Data] {
        let compressed = try Self.compressInstruction(instruction.encode())
        return try fragmenter.fragment(compressed).map { fragment in
            let packet = packetize(fragment.toData())
            sendSequenceNumber += 1
            let nonce = MoshNonce(direction: .toServer, sequenceNumber: sendSequenceNumber)
            return try cryptoSession.encrypt(plaintext: packet, nonce: nonce)
        }
    }

    private func packetize(_ payload: Data) -> Data {
        var packet = Data(capacity: 4 + payload.count)
        let timestamp = UInt16(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1_000))
        packet.append(UInt8((timestamp >> 8) & 0xFF))
        packet.append(UInt8(timestamp & 0xFF))
        packet.append(UInt8((lastRemoteTimestamp >> 8) & 0xFF))
        packet.append(UInt8(lastRemoteTimestamp & 0xFF))
        packet.append(payload)
        return packet
    }

    private func depacketize(_ packet: Data) throws -> Data {
        guard packet.count >= 4 else {
            throw MoshSessionError.packetTooShort(packet.count)
        }

        lastRemoteTimestamp = (UInt16(packet[0]) << 8) | UInt16(packet[1])
        return Data(packet.dropFirst(4))
    }

    private static func compressInstruction(_ instruction: Data) throws -> Data {
        var destinationLength = compressBound(uLong(instruction.count))
        var destination = Data(count: Int(destinationLength))

        let status = destination.withUnsafeMutableBytes { destinationBuffer in
            instruction.withUnsafeBytes { sourceBuffer in
                compress(
                    destinationBuffer.bindMemory(to: Bytef.self).baseAddress,
                    &destinationLength,
                    sourceBuffer.bindMemory(to: Bytef.self).baseAddress,
                    uLong(instruction.count)
                )
            }
        }

        guard status == Z_OK else {
            throw MoshSessionError.compressionFailed(Int(status))
        }

        destination.removeSubrange(Int(destinationLength)..<destination.count)
        return destination
    }

    private static func decompress(_ compressedInstruction: Data) throws -> Data {
        let maximumBufferSize = 4 * 1_024 * 1_024
        var bufferSize = max(1_024, compressedInstruction.count * 8)

        while bufferSize <= maximumBufferSize {
            var destinationLength = uLong(bufferSize)
            var destination = Data(count: bufferSize)

            let status = destination.withUnsafeMutableBytes { destinationBuffer in
                compressedInstruction.withUnsafeBytes { sourceBuffer in
                    uncompress(
                        destinationBuffer.bindMemory(to: Bytef.self).baseAddress,
                        &destinationLength,
                        sourceBuffer.bindMemory(to: Bytef.self).baseAddress,
                        uLong(compressedInstruction.count)
                    )
                }
            }

            if status == Z_OK {
                destination.removeSubrange(Int(destinationLength)..<destination.count)
                return destination
            }

            if status == Z_BUF_ERROR {
                bufferSize *= 2
                continue
            }

            throw MoshSessionError.decompressionFailed(Int(status))
        }

        throw MoshSessionError.decompressionOverflow
    }
}
