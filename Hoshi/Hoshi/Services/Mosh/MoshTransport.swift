import Foundation

// A single transport fragment within a mosh datagram
// Wire format: 8-byte instruction ID + 2-byte fragment number (high bit = final) + payload
struct MoshFragment {
    static let headerLength = 10

    let instructionID: UInt64
    let fragmentNumber: UInt16
    let isFinal: Bool
    let contents: Data

    // Parse a fragment from decrypted plaintext
    init(fromPayload data: Data) throws {
        guard data.count >= MoshFragment.headerLength else {
            throw MoshTransportError.fragmentTooShort
        }

        // Read instruction ID (big-endian uint64)
        var id: UInt64 = 0
        for i in 0..<8 {
            id = (id << 8) | UInt64(data[i])
        }
        self.instructionID = id

        // Read fragment number (big-endian uint16, high bit = final flag)
        let rawFragNum = UInt16(data[8]) << 8 | UInt16(data[9])
        self.isFinal = (rawFragNum & 0x8000) != 0
        self.fragmentNumber = rawFragNum & 0x7FFF

        // Remaining bytes are payload
        self.contents = data.count > MoshFragment.headerLength
            ? data[MoshFragment.headerLength...]
            : Data()
    }

    // Construct a fragment for sending
    init(instructionID: UInt64, fragmentNumber: UInt16, isFinal: Bool, contents: Data) {
        self.instructionID = instructionID
        self.fragmentNumber = fragmentNumber
        self.isFinal = isFinal
        self.contents = contents
    }

    // Serialize to bytes for encryption
    func toData() -> Data {
        var data = Data(capacity: MoshFragment.headerLength + contents.count)
        // Write instruction ID as big-endian uint64
        for i in (0..<8).reversed() {
            data.append(UInt8((instructionID >> (i * 8)) & 0xFF))
        }
        // Write fragment number with final flag
        var rawFragNum = fragmentNumber & 0x7FFF
        if isFinal { rawFragNum |= 0x8000 }
        data.append(UInt8(rawFragNum >> 8))
        data.append(UInt8(rawFragNum & 0xFF))
        // Write payload
        data.append(contents)
        return data
    }
}

// Reassembles fragments into complete transport instructions
final class MoshFragmentAssembly {
    // Pending fragments keyed by instruction ID
    private var pending: [UInt64: [UInt16: Data]] = [:]
    private var finalCounts: [UInt64: UInt16] = [:]

    // Add a fragment. Returns the complete instruction if all fragments arrived.
    func addFragment(_ fragment: MoshFragment) -> Data? {
        let id = fragment.instructionID
        if pending[id] == nil { pending[id] = [:] }
        pending[id]![fragment.fragmentNumber] = fragment.contents

        if fragment.isFinal {
            finalCounts[id] = fragment.fragmentNumber
        }

        // Check if we have all fragments (0 through finalFragNum)
        guard let finalNum = finalCounts[id] else { return nil }
        let expectedCount = Int(finalNum) + 1
        guard pending[id]!.count == expectedCount else { return nil }

        // Reassemble in order
        var result = Data()
        for i in 0..<expectedCount {
            if let fragmentData = pending[id]![UInt16(i)] {
                result.append(fragmentData)
            }
        }

        // Clean up
        pending.removeValue(forKey: id)
        finalCounts.removeValue(forKey: id)

        return result
    }

    func reset() {
        pending.removeAll()
        finalCounts.removeAll()
    }
}

// Breaks a transport instruction into MTU-sized fragments
final class MoshFragmenter {
    // Max payload per fragment (total datagram MTU minus crypto overhead minus fragment header)
    // Mosh default: ~1300 bytes safe for most networks
    let maxPayloadSize: Int

    private var nextInstructionID: UInt64 = 0

    init(maxPayloadSize: Int = 1200) {
        self.maxPayloadSize = maxPayloadSize
    }

    // Break an instruction into fragments
    func fragment(_ instruction: Data) -> [MoshFragment] {
        let id = nextInstructionID
        nextInstructionID += 1

        if instruction.count <= maxPayloadSize {
            // Single fragment (common case)
            return [MoshFragment(
                instructionID: id,
                fragmentNumber: 0,
                isFinal: true,
                contents: instruction
            )]
        }

        // Multi-fragment
        var fragments: [MoshFragment] = []
        var offset = 0
        var fragNum: UInt16 = 0

        while offset < instruction.count {
            let end = min(offset + maxPayloadSize, instruction.count)
            let chunk = instruction[offset..<end]
            let isFinal = end == instruction.count
            fragments.append(MoshFragment(
                instructionID: id,
                fragmentNumber: fragNum,
                isFinal: isFinal,
                contents: Data(chunk)
            ))
            offset = end
            fragNum += 1
        }

        return fragments
    }
}

// Mosh transport instruction encoding/decoding
// Uses a simplified binary format matching the mosh protobuf wire layout
struct MoshTransportInstruction {
    var protocolVersion: UInt32 = 2
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff: Data = Data()

    // Encode as a simple length-prefixed binary format for transport
    // Format: Each field is a 1-byte tag + varint length + value
    // This matches enough of the protobuf wire format to interop with mosh-server
    func encode() -> Data {
        var data = Data()

        // Field 1: protocol_version (varint, tag = 0x08)
        data.append(0x08)
        appendVarint(&data, UInt64(protocolVersion))

        // Field 2: old_num (varint, tag = 0x10)
        data.append(0x10)
        appendVarint(&data, oldNum)

        // Field 3: new_num (varint, tag = 0x18)
        data.append(0x18)
        appendVarint(&data, newNum)

        // Field 4: ack_num (varint, tag = 0x20)
        data.append(0x20)
        appendVarint(&data, ackNum)

        // Field 5: throwaway_num (varint, tag = 0x28)
        data.append(0x28)
        appendVarint(&data, throwawayNum)

        // Field 6: diff (length-delimited bytes, tag = 0x32)
        if !diff.isEmpty {
            data.append(0x32)
            appendVarint(&data, UInt64(diff.count))
            data.append(diff)
        }

        return data
    }

    // Decode from protobuf wire format
    static func decode(from data: Data) throws -> MoshTransportInstruction {
        var instruction = MoshTransportInstruction()
        var offset = 0
        let bytes = Array(data)

        while offset < bytes.count {
            let tag = bytes[offset]
            offset += 1

            switch tag {
            case 0x08: // protocol_version
                let (value, newOffset) = try readVarint(bytes, offset: offset)
                instruction.protocolVersion = UInt32(value)
                offset = newOffset

            case 0x10: // old_num
                let (value, newOffset) = try readVarint(bytes, offset: offset)
                instruction.oldNum = value
                offset = newOffset

            case 0x18: // new_num
                let (value, newOffset) = try readVarint(bytes, offset: offset)
                instruction.newNum = value
                offset = newOffset

            case 0x20: // ack_num
                let (value, newOffset) = try readVarint(bytes, offset: offset)
                instruction.ackNum = value
                offset = newOffset

            case 0x28: // throwaway_num
                let (value, newOffset) = try readVarint(bytes, offset: offset)
                instruction.throwawayNum = value
                offset = newOffset

            case 0x32: // diff (length-delimited)
                let (length, newOffset) = try readVarint(bytes, offset: offset)
                let end = newOffset + Int(length)
                guard end <= bytes.count else {
                    throw MoshTransportError.invalidInstruction
                }
                instruction.diff = Data(bytes[newOffset..<end])
                offset = end

            case 0x3A: // chaff (field 7, length-delimited) - skip
                let (length, newOffset) = try readVarint(bytes, offset: offset)
                offset = newOffset + Int(length)

            default:
                // Skip unknown fields based on wire type
                let wireType = tag & 0x07
                switch wireType {
                case 0: // varint
                    let (_, newOffset) = try readVarint(bytes, offset: offset)
                    offset = newOffset
                case 2: // length-delimited
                    let (length, newOffset) = try readVarint(bytes, offset: offset)
                    offset = newOffset + Int(length)
                default:
                    throw MoshTransportError.invalidInstruction
                }
            }
        }

        return instruction
    }
}

// User input instruction (keystroke or resize) encoded as protobuf
struct MoshUserInput {
    // Encode keystrokes as a ClientBuffers.UserMessage
    // Field structure: UserMessage { repeated Instruction { keys(4), width(5), height(6) } }
    static func encodeKeystroke(_ keys: Data) -> Data {
        var inner = Data()
        // Instruction.keys (field 4, length-delimited, tag = 0x22)
        inner.append(0x22)
        appendVarint(&inner, UInt64(keys.count))
        inner.append(keys)

        var outer = Data()
        // UserMessage.instruction (field 1, length-delimited, tag = 0x0A)
        outer.append(0x0A)
        appendVarint(&outer, UInt64(inner.count))
        outer.append(inner)

        return outer
    }

    // Encode a terminal resize as a ClientBuffers.UserMessage
    static func encodeResize(width: Int32, height: Int32) -> Data {
        var inner = Data()
        // Instruction.width (field 5, varint, tag = 0x28)
        inner.append(0x28)
        appendVarint(&inner, UInt64(bitPattern: Int64(width)))
        // Instruction.height (field 6, varint, tag = 0x30)
        inner.append(0x30)
        appendVarint(&inner, UInt64(bitPattern: Int64(height)))

        var outer = Data()
        // UserMessage.instruction (field 1, length-delimited, tag = 0x0A)
        outer.append(0x0A)
        appendVarint(&outer, UInt64(inner.count))
        outer.append(inner)

        return outer
    }
}

// Decoded host output from server
struct MoshHostOutput {
    let hostString: Data?
    let echoAck: Int64?

    // Decode a HostBuffers.HostMessage
    static func decode(from data: Data) throws -> [MoshHostOutput] {
        var results: [MoshHostOutput] = []
        var offset = 0
        let bytes = Array(data)

        while offset < bytes.count {
            let tag = bytes[offset]
            offset += 1

            if tag == 0x0A {
                // HostMessage.instruction (field 1, length-delimited)
                let (length, newOffset) = try readVarint(bytes, offset: offset)
                let end = newOffset + Int(length)
                guard end <= bytes.count else { break }
                let instructionBytes = Array(bytes[newOffset..<end])
                let output = try decodeInstruction(instructionBytes)
                results.append(output)
                offset = end
            } else {
                // Skip unknown field
                let wireType = tag & 0x07
                switch wireType {
                case 0:
                    let (_, newOffset) = try readVarint(bytes, offset: offset)
                    offset = newOffset
                case 2:
                    let (length, newOffset) = try readVarint(bytes, offset: offset)
                    offset = newOffset + Int(length)
                default:
                    break
                }
            }
        }

        return results
    }

    // Decode a single HostBuffers.Instruction
    private static func decodeInstruction(_ bytes: [UInt8]) throws -> MoshHostOutput {
        var hostString: Data?
        var echoAck: Int64?
        var offset = 0

        while offset < bytes.count {
            let tag = bytes[offset]
            offset += 1

            switch tag {
            case 0x22: // hoststring (field 4, length-delimited)
                let (length, newOffset) = try readVarint(bytes, offset: offset)
                let end = newOffset + Int(length)
                guard end <= bytes.count else { break }
                hostString = Data(bytes[newOffset..<end])
                offset = end

            case 0x38: // echo_ack (field 7, varint)
                let (value, newOffset) = try readVarint(bytes, offset: offset)
                echoAck = Int64(bitPattern: value)
                offset = newOffset

            default:
                let wireType = tag & 0x07
                switch wireType {
                case 0:
                    let (_, newOffset) = try readVarint(bytes, offset: offset)
                    offset = newOffset
                case 2:
                    let (length, newOffset) = try readVarint(bytes, offset: offset)
                    offset = newOffset + Int(length)
                default:
                    offset = bytes.count
                }
            }
        }

        return MoshHostOutput(hostString: hostString, echoAck: echoAck)
    }
}

// MARK: - Protobuf Varint Helpers

private func appendVarint(_ data: inout Data, _ value: UInt64) {
    var v = value
    while v > 0x7F {
        data.append(UInt8(v & 0x7F) | 0x80)
        v >>= 7
    }
    data.append(UInt8(v))
}

private func readVarint(_ bytes: [UInt8], offset: Int) throws -> (UInt64, Int) {
    var result: UInt64 = 0
    var shift = 0
    var pos = offset

    while pos < bytes.count {
        let byte = bytes[pos]
        result |= UInt64(byte & 0x7F) << shift
        pos += 1
        if byte & 0x80 == 0 {
            return (result, pos)
        }
        shift += 7
        if shift >= 64 { throw MoshTransportError.invalidVarint }
    }

    throw MoshTransportError.invalidVarint
}

enum MoshTransportError: LocalizedError {
    case fragmentTooShort
    case invalidInstruction
    case invalidVarint
    case reassemblyFailed

    var errorDescription: String? {
        switch self {
        case .fragmentTooShort:
            return "Mosh transport fragment too short"
        case .invalidInstruction:
            return "Invalid mosh transport instruction"
        case .invalidVarint:
            return "Invalid varint in mosh transport data"
        case .reassemblyFailed:
            return "Failed to reassemble mosh transport fragments"
        }
    }
}
