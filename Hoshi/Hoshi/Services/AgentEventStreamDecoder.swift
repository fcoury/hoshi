import Foundation

struct AgentEventStreamResult: Equatable, Sendable {
    let terminalOutput: Data
    let events: [AgentEventEnvelope]
}

/// Decodes bounded Hoshi OSC events without altering unrelated terminal control sequences.
actor AgentEventStreamDecoder {
    static let prefix = Data([0x1B, 0x5D]) + Data("777;hoshi;".utf8)
    static let maximumEncodedPayloadBytes = 24_576
    static let maximumDecodedPayloadBytes = 16_384

    private var pending = Data()

    func ingest(_ bytes: Data) -> AgentEventStreamResult {
        guard !bytes.isEmpty else {
            return AgentEventStreamResult(terminalOutput: Data(), events: [])
        }

        pending.append(bytes)
        var output = Data()
        var events: [AgentEventEnvelope] = []

        while !pending.isEmpty {
            guard let prefixRange = pending.range(of: Self.prefix) else {
                let retained = partialPrefixLength(in: pending)
                output.append(pending.prefix(pending.count - retained))
                pending = Data(pending.suffix(retained))
                break
            }

            output.append(pending[..<prefixRange.lowerBound])
            pending.removeSubrange(..<prefixRange.lowerBound)

            guard let terminator = terminatorRange(in: pending, startingAt: Self.prefix.count) else {
                if pending.count > Self.prefix.count + Self.maximumEncodedPayloadBytes {
                    // Never retain attacker-controlled terminal output indefinitely.
                    output.append(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                break
            }

            let original = Data(pending[..<terminator.upperBound])
            let encoded = Data(pending[Self.prefix.count..<terminator.lowerBound])
            pending.removeSubrange(..<terminator.upperBound)

            if let event = Self.decode(encoded) {
                events.append(event)
            } else {
                // Unknown, malformed, and unsupported OSC payloads must remain visible to Ghostty.
                output.append(original)
            }
        }

        return AgentEventStreamResult(terminalOutput: output, events: events)
    }

    func reset() {
        pending.removeAll(keepingCapacity: false)
    }

    nonisolated static func encode(_ event: AgentEventEnvelope, terminator: Data = Data([0x07])) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(event)
        return prefix + Data(payload.base64EncodedString().utf8) + terminator
    }

    private nonisolated static func decode(_ encoded: Data) -> AgentEventEnvelope? {
        guard encoded.count <= maximumEncodedPayloadBytes,
              let payload = Data(base64Encoded: encoded),
              payload.count <= maximumDecodedPayloadBytes else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let event = try? decoder.decode(AgentEventEnvelope.self, from: payload), event.isValid else {
            return nil
        }
        return event
    }

    private func terminatorRange(in data: Data, startingAt start: Int) -> Range<Data.Index>? {
        guard start < data.count else { return nil }
        var index = start

        while index < data.count {
            if data[index] == 0x07 {
                return index..<(index + 1)
            }
            if data[index] == 0x1B,
               index + 1 < data.count,
               data[index + 1] == 0x5C {
                return index..<(index + 2)
            }
            index += 1
        }

        return nil
    }

    private func partialPrefixLength(in data: Data) -> Int {
        let maximum = min(data.count, Self.prefix.count - 1)
        guard maximum > 0 else { return 0 }

        for count in stride(from: maximum, through: 1, by: -1) {
            if data.suffix(count).elementsEqual(Self.prefix.prefix(count)) {
                return count
            }
        }
        return 0
    }
}
