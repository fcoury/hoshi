import Foundation
import zlib

struct MoshDecodedDatagram: Sendable {
    let instruction: MoshTransportInstruction
    let outputs: [MoshHostOutput]
    /// Round-trip sample from the packet's echoed timestamp, when the peer sent one.
    var roundTripSample: TimeInterval? = nil
}

/// Mosh-style round-trip estimation from SSP packet timestamps.
///
/// Every SSP packet carries the sender's 16-bit millisecond clock and an echo of
/// the last timestamp it received (already adjusted by the peer for hold time).
/// `0xFFFF` means "no echo". Smoothing follows mosh's SRTT (RFC 6298, alpha 1/8).
struct MoshRoundTripEstimator: Equatable, Sendable {
    static let noReply: UInt16 = 0xFFFF
    /// mosh ignores samples this large as stale or clock-wrapped.
    static let maximumSampleMilliseconds: UInt16 = 5_000

    private(set) var smoothed: TimeInterval?

    static func sample(now: UInt16, reply: UInt16) -> TimeInterval? {
        guard reply != noReply else { return nil }
        let milliseconds = now &- reply
        guard milliseconds < maximumSampleMilliseconds else { return nil }
        return TimeInterval(milliseconds) / 1_000
    }

    @discardableResult
    mutating func record(_ sample: TimeInterval) -> TimeInterval {
        let next = smoothed.map { $0 * 0.875 + sample * 0.125 } ?? sample
        smoothed = next
        return next
    }

    mutating func reset() {
        smoothed = nil
    }

    /// mosh's 16-bit millisecond packet clock. Any monotonic clock works: the peer only echoes it.
    static func timestamp(seconds: TimeInterval) -> UInt16 {
        UInt16(truncatingIfNeeded: UInt64(max(0, seconds) * 1_000))
    }
}

enum MoshProtocolError: Error, Equatable {
    /// The datagram failed authentication (or isn't a mosh datagram for this session).
    /// mosh drops these silently: anyone who can reach the UDP port can send them.
    case unauthenticated
}

/// Owns mutable SSP framing and crypto state away from the UI/main actor.
actor MoshProtocolEngine {
    private let cryptoSession: MoshCryptoSession
    private let clock: @Sendable () -> TimeInterval
    private var fragmentAssembly = MoshFragmentAssembly()
    private var fragmenter = MoshFragmenter()
    private var sendSequenceNumber: UInt64 = 0
    /// Datagrams below this sequence number are out of order or replayed: their contents
    /// still count, but not their timestamps (as in mosh's `Connection::recv_one`).
    private var expectedReceiveSequence: UInt64 = 0
    /// The peer's latest timestamp and when it arrived, echoed once in our next packet.
    private var savedRemoteTimestamp: UInt16?
    private var savedRemoteTimestampReceivedAt: TimeInterval = 0

    /// mosh only echoes a timestamp it received within this window.
    static let maximumTimestampHold: TimeInterval = 1

    init(key: Data, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.cryptoSession = try MoshCryptoSession(key: key)
        self.clock = clock
    }

    func discardIncompleteFragments() {
        fragmentAssembly.reset()
    }

    func decode(_ datagram: Data, direction: MoshDirection = .toClient) throws -> MoshDecodedDatagram? {
        let plaintext: Data
        let sequenceNumber: UInt64
        do {
            (plaintext, sequenceNumber) = try cryptoSession.decrypt(datagram: datagram, direction: direction)
        } catch {
            throw MoshProtocolError.unauthenticated
        }
        let inOrder = sequenceNumber >= expectedReceiveSequence
        if inOrder {
            expectedReceiveSequence = sequenceNumber + 1
        }
        let (payload, roundTripSample) = try depacketize(plaintext, inOrder: inOrder)
        let fragment = try MoshFragment(fromPayload: payload)

        guard let compressedInstruction = fragmentAssembly.addFragment(fragment) else {
            return nil
        }

        let instruction = try MoshTransportInstruction.decode(
            from: Self.decompress(compressedInstruction)
        )
        let outputs = instruction.diff.isEmpty ? [] : try MoshHostOutput.decode(from: instruction.diff)
        return MoshDecodedDatagram(
            instruction: instruction,
            outputs: outputs,
            roundTripSample: roundTripSample
        )
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
        let now = clock()
        var packet = Data(capacity: 4 + payload.count)
        let timestamp = MoshRoundTripEstimator.timestamp(seconds: now)
        packet.append(UInt8((timestamp >> 8) & 0xFF))
        packet.append(UInt8(timestamp & 0xFF))

        // Echo the peer's timestamp once, advanced by how long we held it, so its RTT
        // estimate (which paces mosh-server's frames and resends) isn't inflated.
        var reply = MoshRoundTripEstimator.noReply
        if let saved = savedRemoteTimestamp {
            let held = now - savedRemoteTimestampReceivedAt
            if held < Self.maximumTimestampHold {
                reply = saved &+ MoshRoundTripEstimator.timestamp(seconds: held)
                if reply == MoshRoundTripEstimator.noReply { reply = 0 }
            }
            savedRemoteTimestamp = nil
        }
        packet.append(UInt8((reply >> 8) & 0xFF))
        packet.append(UInt8(reply & 0xFF))
        packet.append(payload)
        return packet
    }

    private func depacketize(
        _ packet: Data,
        inOrder: Bool
    ) throws -> (payload: Data, roundTripSample: TimeInterval?) {
        guard packet.count >= 4 else {
            throw MoshSessionError.packetTooShort(packet.count)
        }

        let start = packet.startIndex
        let payload = Data(packet.dropFirst(4))
        guard inOrder else { return (payload, nil) }

        let timestamp = (UInt16(packet[start]) << 8) | UInt16(packet[start + 1])
        if timestamp != MoshRoundTripEstimator.noReply {
            savedRemoteTimestamp = timestamp
            savedRemoteTimestampReceivedAt = clock()
        }
        let reply = (UInt16(packet[start + 2]) << 8) | UInt16(packet[start + 3])
        let sample = MoshRoundTripEstimator.sample(
            now: MoshRoundTripEstimator.timestamp(seconds: clock()),
            reply: reply
        )
        return (payload, sample)
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
