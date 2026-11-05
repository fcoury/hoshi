import Foundation

// A single transport fragment within a mosh datagram
// Wire format: 8-byte instruction ID + 2-byte fragment number (high bit = final) + payload
struct MoshFragment: Sendable {
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

// Reassembles fragments into complete transport instructions.
//
// Like mosh, only the instruction currently being assembled is kept: a fragment of a
// different instruction replaces it. The sender always moves on to newer instructions,
// so an incomplete older one will never finish and would otherwise be kept forever.
final class MoshFragmentAssembly {
    private var currentID: UInt64?
    private var fragments: [UInt16: Data] = [:]
    private var finalFragmentNumber: UInt16?

    // Add a fragment. Returns the complete instruction if all fragments arrived.
    func addFragment(_ fragment: MoshFragment) -> Data? {
        if currentID != fragment.instructionID {
            reset()
            currentID = fragment.instructionID
        }
        fragments[fragment.fragmentNumber] = fragment.contents
        if fragment.isFinal {
            finalFragmentNumber = fragment.fragmentNumber
        }

        guard let finalNumber = finalFragmentNumber,
              fragments.count == Int(finalNumber) + 1 else { return nil }

        var result = Data()
        for number in 0...finalNumber {
            guard let contents = fragments[number] else { return nil }
            result.append(contents)
        }
        reset()
        return result
    }

    func reset() {
        currentID = nil
        fragments.removeAll()
        finalFragmentNumber = nil
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
struct MoshTransportInstruction: Sendable {
    var protocolVersion: UInt32 = 2
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff: Data = Data()
    var chaff: Data = Data()

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

        // Field 7: chaff (length-delimited bytes, tag = 0x3A)
        if !chaff.isEmpty {
            data.append(0x3A)
            appendVarint(&data, UInt64(chaff.count))
            data.append(chaff)
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
                let end = try checkedEnd(newOffset, length, in: bytes)
                instruction.diff = Data(bytes[newOffset..<end])
                offset = end

            case 0x3A: // chaff (field 7, length-delimited) - skip
                let (length, newOffset) = try readVarint(bytes, offset: offset)
                let end = try checkedEnd(newOffset, length, in: bytes)
                instruction.chaff = Data(bytes[newOffset..<end])
                offset = end

            default:
                offset = try skipField(tag: tag, bytes, offset: offset)
            }
        }

        return instruction
    }
}

// User input instruction (keystroke or resize) encoded as protobuf
struct MoshUserInput {
    // Encode keystrokes as:
    // UserMessage.instruction(1) -> Instruction.keystroke extension(2) -> Keystroke.keys(4)
    static func encodeKeystroke(_ keys: Data) -> Data {
        var keystroke = Data()
        keystroke.append(0x22) // Keystroke.keys (field 4, length-delimited)
        appendVarint(&keystroke, UInt64(keys.count))
        keystroke.append(keys)

        var instruction = Data()
        instruction.append(0x12) // Instruction.keystroke extension (field 2, length-delimited)
        appendVarint(&instruction, UInt64(keystroke.count))
        instruction.append(keystroke)

        var outer = Data()
        outer.append(0x0A) // UserMessage.instruction (field 1, length-delimited)
        appendVarint(&outer, UInt64(instruction.count))
        outer.append(instruction)

        return outer
    }

    // Encode resize as:
    // UserMessage.instruction(1) -> Instruction.resize extension(3) -> ResizeMessage.width(5),height(6)
    static func encodeResize(width: Int32, height: Int32) -> Data {
        var resize = Data()
        resize.append(0x28) // ResizeMessage.width (field 5, varint)
        appendVarint(&resize, UInt64(bitPattern: Int64(width)))
        resize.append(0x30) // ResizeMessage.height (field 6, varint)
        appendVarint(&resize, UInt64(bitPattern: Int64(height)))

        var instruction = Data()
        instruction.append(0x1A) // Instruction.resize extension (field 3, length-delimited)
        appendVarint(&instruction, UInt64(resize.count))
        instruction.append(resize)

        var outer = Data()
        outer.append(0x0A) // UserMessage.instruction (field 1, length-delimited)
        appendVarint(&outer, UInt64(instruction.count))
        outer.append(instruction)

        return outer
    }
}

// Decoded host output from server
struct MoshHostOutput: Sendable {
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
                let end = try checkedEnd(newOffset, length, in: bytes)
                let instructionBytes = Array(bytes[newOffset..<end])
                let output = try decodeInstruction(instructionBytes)
                results.append(output)
                offset = end
            } else {
                offset = try skipField(tag: tag, bytes, offset: offset)
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
            case 0x12: // Instruction.hostbytes extension (field 2, length-delimited)
                let (length, start) = try readVarint(bytes, offset: offset)
                let end = try checkedEnd(start, length, in: bytes)
                hostString = try decodeHostBytes(Array(bytes[start..<end]))
                offset = end

            case 0x3A: // Instruction.echoack extension (field 7, length-delimited)
                let (length, start) = try readVarint(bytes, offset: offset)
                let end = try checkedEnd(start, length, in: bytes)
                echoAck = try decodeEchoAck(Array(bytes[start..<end]))
                offset = end

            default:
                offset = try skipField(tag: tag, bytes, offset: offset)
            }
        }

        return MoshHostOutput(hostString: hostString, echoAck: echoAck)
    }

    private static func decodeHostBytes(_ bytes: [UInt8]) throws -> Data? {
        var offset = 0
        while offset < bytes.count {
            let tag = bytes[offset]
            offset += 1

            switch tag {
            case 0x22: // HostBytes.hoststring (field 4, length-delimited)
                let (length, start) = try readVarint(bytes, offset: offset)
                let end = try checkedEnd(start, length, in: bytes)
                return Data(bytes[start..<end])
            default:
                offset = try skipField(tag: tag, bytes, offset: offset)
            }
        }
        return nil
    }

    private static func decodeEchoAck(_ bytes: [UInt8]) throws -> Int64? {
        var offset = 0
        while offset < bytes.count {
            let tag = bytes[offset]
            offset += 1

            switch tag {
            case 0x40: // EchoAck.echo_ack_num (field 8, varint)
                let (value, _) = try readVarint(bytes, offset: offset)
                return Int64(bitPattern: value)
            default:
                offset = try skipField(tag: tag, bytes, offset: offset)
            }
        }
        return nil
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

/// The end of a length-delimited field that starts at `start`, or an error if the length
/// runs past the buffer. Lengths come off the wire, so they must never trap.
private func checkedEnd(_ start: Int, _ length: UInt64, in bytes: [UInt8]) throws -> Int {
    guard start <= bytes.count, length <= UInt64(bytes.count - start) else {
        throw MoshTransportError.invalidInstruction
    }
    return start + Int(length)
}

/// Skips one field of an unknown tag and returns the offset after it.
private func skipField(tag: UInt8, _ bytes: [UInt8], offset: Int) throws -> Int {
    switch tag & 0x07 {
    case 0:
        return try readVarint(bytes, offset: offset).1
    case 2:
        let (length, start) = try readVarint(bytes, offset: offset)
        return try checkedEnd(start, length, in: bytes)
    default:
        throw MoshTransportError.invalidInstruction
    }
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
