import XCTest
@testable import Hoshi

final class MoshTransportSenderTests: XCTestCase {
    private let timeout: TimeInterval = 1

    func testBurstOfInputBeforeSendingBecomesOneState() throws {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        sender.enqueue(Data("b".utf8))

        let instruction = try XCTUnwrap(sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 7))
        XCTAssertEqual(instruction.oldNum, 0)
        XCTAssertEqual(instruction.newNum, 1)
        XCTAssertEqual(instruction.ackNum, 7)
        XCTAssertEqual(instruction.diff, Data("ab".utf8))
        XCTAssertNil(sender.nextInstruction(now: 0.1, timeout: timeout, remoteAck: 7), "Nothing new to send")
    }

    func testLostStateIsResentFromTheAcknowledgedBase() throws {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        _ = sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 0)

        // Sent recently, so the next state builds on it, as in mosh.
        sender.enqueue(Data("b".utf8))
        let second = try XCTUnwrap(sender.nextInstruction(now: 0.1, timeout: timeout, remoteAck: 0))
        XCTAssertEqual(second.oldNum, 1)
        XCTAssertEqual(second.newNum, 2)
        XCTAssertEqual(second.diff, Data("b".utf8))

        // State 1 was lost and nothing was acknowledged: mosh-server drops every diff built
        // on state 1, so after the timeout everything goes again from state 0.
        XCTAssertNil(sender.nextInstruction(now: 0.5, timeout: timeout, remoteAck: 0))
        let resend = try XCTUnwrap(sender.nextInstruction(now: 1.2, timeout: timeout, remoteAck: 0))
        XCTAssertEqual(resend.oldNum, 0)
        XCTAssertEqual(resend.newNum, 2)
        XCTAssertEqual(resend.diff, Data("ab".utf8))
    }

    func testAcknowledgementMovesTheBaseAndLetsTheServerDiscardStates() throws {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        _ = sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 0)
        sender.acknowledge(1)

        sender.enqueue(Data("b".utf8))
        let next = try XCTUnwrap(sender.nextInstruction(now: 5, timeout: timeout, remoteAck: 0))
        XCTAssertEqual(next.oldNum, 1)
        XCTAssertEqual(next.newNum, 2)
        XCTAssertEqual(next.throwawayNum, 1)
        XCTAssertEqual(next.diff, Data("b".utf8))
    }

    func testStateQueueStaysBoundedOverALongSession() {
        // mosh-server only accepts one state per 15 s once it holds over 1,024 of them,
        // so it must be told to discard acknowledged ones.
        var sender = MoshTransportSender()
        var lastThrowaway: UInt64 = 0
        for keystroke in 0..<2_000 {
            sender.enqueue(Data([UInt8(truncatingIfNeeded: keystroke)]))
            let instruction = sender.nextInstruction(now: TimeInterval(keystroke), timeout: timeout, remoteAck: 0)
            XCTAssertNotNil(instruction)
            lastThrowaway = instruction?.throwawayNum ?? 0
            sender.acknowledge(sender.currentNum)
        }
        XCTAssertTrue(sender.unacked.isEmpty)
        XCTAssertEqual(lastThrowaway, 1_999)
    }

    func testInputAfterAResetNeverChangesAStateThatMayHaveBeenSent() throws {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        _ = sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 0)
        sender.resendFromAcknowledgedState()

        // mosh-server ignores a repeated state number, so "b" must not join state 1.
        sender.enqueue(Data("b".utf8))
        let next = try XCTUnwrap(sender.nextInstruction(now: 0.01, timeout: timeout, remoteAck: 0))
        XCTAssertEqual(next.oldNum, 0)
        XCTAssertEqual(next.newNum, 2)
        XCTAssertEqual(next.diff, Data("ab".utf8))
    }

    func testResendAfterSocketReplacementGoesImmediatelyFromTheAcknowledgedBase() throws {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        _ = sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 0)
        sender.enqueue(Data("b".utf8))
        _ = sender.nextInstruction(now: 0.1, timeout: timeout, remoteAck: 0)

        sender.resendFromAcknowledgedState()
        let resend = try XCTUnwrap(sender.nextInstruction(now: 0.2, timeout: timeout, remoteAck: 0))
        XCTAssertEqual(resend.oldNum, 0)
        XCTAssertEqual(resend.newNum, 2)
        XCTAssertEqual(resend.diff, Data("ab".utf8))
    }

    func testAcknowledgementsForUnknownStatesAreIgnored() {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        sender.acknowledge(MoshTransportSender.shutdownStateNum)
        sender.acknowledge(5)
        XCTAssertEqual(sender.ackedNum, 0)
        XCTAssertEqual(sender.unacked.count, 1)
    }

    func testShutdownCarriesUnacknowledgedInputAndKeptBase() {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        _ = sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 0)
        sender.acknowledge(1)
        sender.enqueue(Data("exit".utf8))

        let shutdown = sender.shutdownInstruction(remoteAck: 9)
        XCTAssertEqual(shutdown.oldNum, 1)
        XCTAssertEqual(shutdown.newNum, MoshTransportSender.shutdownStateNum)
        XCTAssertEqual(shutdown.throwawayNum, 1)
        XCTAssertEqual(shutdown.ackNum, 9)
        XCTAssertEqual(shutdown.diff, Data("exit".utf8))
    }

    func testAcknowledgementInstructionBuildsOnAStateTheServerKeeps() {
        var sender = MoshTransportSender()
        sender.enqueue(Data("a".utf8))
        _ = sender.nextInstruction(now: 0, timeout: timeout, remoteAck: 0)
        sender.acknowledge(1)

        let ack = sender.acknowledgementInstruction(remoteAck: 4)
        XCTAssertEqual(ack.oldNum, 1)
        XCTAssertEqual(ack.newNum, 1)
        XCTAssertEqual(ack.throwawayNum, 1)
        XCTAssertEqual(ack.ackNum, 4)
        XCTAssertTrue(ack.diff.isEmpty)
    }
}

final class MoshProtocolEngineTests: XCTestCase {
    private let key = Data(repeating: 0x5A, count: 16)

    func testTimestampIsEchoedOnceAndAdvancedByHoldTime() async throws {
        let clientClock = TestClock(50)
        let client = try MoshProtocolEngine(key: key) { clientClock.now }
        _ = try await client.decode(await serverDatagram(timestampAt: 10, sequence: 1))

        clientClock.now = 50.2
        let reply1 = try await sentTimestampReply(from: client)

        XCTAssertEqual(reply1, MoshRoundTripEstimator.timestamp(seconds: 10.2))
        let reply2 = try await sentTimestampReply(from: client)

        XCTAssertEqual(reply2, MoshRoundTripEstimator.noReply, "Echo only once")
    }

    func testStaleTimestampIsNotEchoed() async throws {
        let clientClock = TestClock(50)
        let client = try MoshProtocolEngine(key: key) { clientClock.now }
        _ = try await client.decode(await serverDatagram(timestampAt: 10, sequence: 1))

        clientClock.now = 51.5
        let reply3 = try await sentTimestampReply(from: client)

        XCTAssertEqual(reply3, MoshRoundTripEstimator.noReply)
    }

    func testOutOfOrderDatagramIsDecodedButItsTimestampIgnored() async throws {
        let clientClock = TestClock(50)
        let client = try MoshProtocolEngine(key: key) { clientClock.now }
        _ = try await client.decode(await serverDatagram(timestampAt: 20, sequence: 5))

        var late = MoshTransportInstruction()
        late.newNum = 3
        let decoded = try await client.decode(await serverDatagram(timestampAt: 10, sequence: 3, instruction: late))
        XCTAssertEqual(decoded?.instruction.newNum, 3, "Contents of a late datagram still count")
        XCTAssertNil(decoded?.roundTripSample)

        clientClock.now = 50.1
        let reply4 = try await sentTimestampReply(from: client)

        XCTAssertEqual(reply4, MoshRoundTripEstimator.timestamp(seconds: 20.1))
    }

    func testForgedDatagramIsReportedAsUnauthenticated() async throws {
        let client = try MoshProtocolEngine(key: key)
        var forged = try await serverDatagram(timestampAt: 1, sequence: 1)
        forged[forged.count - 1] ^= 0xFF

        for datagram in [forged, Data(repeating: 0xAB, count: 64), Data([0x01])] {
            do {
                _ = try await client.decode(datagram)
                XCTFail("Expected an unauthenticated datagram error")
            } catch {
                XCTAssertEqual(error as? MoshProtocolError, .unauthenticated)
            }
        }
    }

    func testIncompleteOlderInstructionIsDiscardedWhenANewerOneStarts() {
        let assembly = MoshFragmentAssembly()
        XCTAssertNil(assembly.addFragment(MoshFragment(instructionID: 1, fragmentNumber: 0, isFinal: false, contents: Data("a".utf8))))
        XCTAssertEqual(
            assembly.addFragment(MoshFragment(instructionID: 2, fragmentNumber: 0, isFinal: true, contents: Data("b".utf8))),
            Data("b".utf8)
        )
        // The rest of instruction 1 can't complete it any more.
        XCTAssertNil(assembly.addFragment(MoshFragment(instructionID: 1, fragmentNumber: 1, isFinal: true, contents: Data("c".utf8))))
    }

    func testMalformedLengthsAreErrorsNotCrashes() {
        // A diff field (tag 0x32) claiming a length of 2^63 bytes.
        let hugeLength: [UInt8] = [0x32, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
        XCTAssertThrowsError(try MoshTransportInstruction.decode(from: Data(hugeLength)))
        XCTAssertThrowsError(try MoshHostOutput.decode(from: Data([0x0A] + hugeLength.dropFirst())))
        // Host bytes whose inner length runs past the end.
        XCTAssertThrowsError(try MoshHostOutput.decode(from: Data([0x0A, 0x04, 0x12, 0x02, 0x22, 0x09])))
    }

    // MARK: - Helpers

    /// A server-to-client datagram whose packet timestamp is `timestampAt` seconds on the server's clock.
    private func serverDatagram(
        timestampAt seconds: TimeInterval,
        sequence: UInt64,
        instruction: MoshTransportInstruction = MoshTransportInstruction()
    ) async throws -> Data {
        let crypto = try MoshCryptoSession(key: key)
        let server = try MoshProtocolEngine(key: key) { seconds }
        let encoded = try await server.encode(instruction)
        let plaintext = try crypto.decrypt(datagram: XCTUnwrap(encoded.first), direction: .toServer).plaintext
        return try crypto.encrypt(plaintext: plaintext, nonce: MoshNonce(direction: .toClient, sequenceNumber: sequence))
    }

    /// The timestamp-reply field of the next packet the client sends.
    private func sentTimestampReply(from client: MoshProtocolEngine) async throws -> UInt16 {
        let encoded = try await client.encode(MoshTransportInstruction())
        let datagram = try XCTUnwrap(encoded.first)
        let plaintext = try MoshCryptoSession(key: key).decrypt(datagram: datagram, direction: .toServer).plaintext
        let bytes = Array(plaintext)
        return UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    }
}

private final class TestClock: @unchecked Sendable {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}

final class MoshStateSyncTests: XCTestCase {
    private func instruction(old: UInt64, new: UInt64, ack: UInt64 = 0) -> MoshTransportInstruction {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = old
        instruction.newNum = new
        instruction.ackNum = ack
        return instruction
    }

    func testOnlyDiffsFromOurExactStateApply() {
        var sync = MoshStateSync()
        XCTAssertEqual(sync.receive(instruction(old: 0, new: 2)), .applied)
        XCTAssertEqual(sync.receive(instruction(old: 0, new: 2)), .stale)
        XCTAssertEqual(sync.receive(instruction(old: 1, new: 3)), .unknownBase, "built on a state we never reached")
        XCTAssertEqual(sync.receive(instruction(old: 0, new: 4)), .unknownBase, "overlaps what we already applied")
        XCTAssertEqual(sync.remoteStateNum, 2)
        XCTAssertEqual(sync.receive(instruction(old: 2, new: 5)), .applied)
        XCTAssertEqual(sync.remoteStateNum, 5)
        XCTAssertFalse(sync.remoteEnded)
    }

    func testAppliedShutdownStateEndsTheSessionButAnUnknownBaseDoesNot() {
        var sync = MoshStateSync()
        _ = sync.receive(instruction(old: 0, new: 3))
        XCTAssertEqual(sync.receive(instruction(old: 1, new: MoshStateSync.shutdownStateNum)), .unknownBase)
        XCTAssertFalse(sync.remoteEnded)
        XCTAssertEqual(sync.receive(instruction(old: 3, new: MoshStateSync.shutdownStateNum)), .applied)
        XCTAssertTrue(sync.remoteEnded)
    }

    func testEveryInstructionCarriesTheServerAck() {
        var sync = MoshStateSync()
        sync.enqueue(MoshUserInput.encodeKeystroke(Data("a".utf8)))
        _ = sync.nextTransmission(now: 0, timeout: 1)
        // Even a stale state acknowledges our input.
        _ = sync.receive(instruction(old: 0, new: 0, ack: 1))
        XCTAssertFalse(sync.sender.hasUnacknowledgedInput)
        XCTAssertFalse(sync.clientShutdownAcknowledged)
        _ = sync.receive(instruction(old: 0, new: 0, ack: MoshStateSync.shutdownStateNum))
        XCTAssertTrue(sync.clientShutdownAcknowledged)
    }

    func testTerminalStartsFromABlankScreenOnce() {
        var sync = MoshStateSync()
        XCTAssertEqual(sync.terminalBytes(Data()), Data(), "an empty first frame doesn't use up the reset")
        XCTAssertEqual(sync.terminalBytes(Data("a".utf8)), MoshStateSync.blankScreen + Data("a".utf8))
        XCTAssertEqual(sync.terminalBytes(Data("b".utf8)), Data("b".utf8))
    }

    func testReceivedStateIsAcknowledgedRightAway() {
        var sync = MoshStateSync()
        sync.resetHeartbeat(now: 100)
        XCTAssertNil(sync.nextTransmission(now: 100.5, timeout: 1))

        _ = sync.receive(instruction(old: 0, new: 7))
        let ack = sync.nextTransmission(now: 100.6, timeout: 1)
        XCTAssertEqual(ack?.ackNum, 7)
        XCTAssertEqual(ack?.diff, Data())
        XCTAssertNil(sync.nextTransmission(now: 100.7, timeout: 1), "one ack per received state")
    }

    func testHeartbeatAfterThreeQuietSeconds() {
        var sync = MoshStateSync()
        sync.resetHeartbeat(now: 10)
        XCTAssertEqual(sync.nextTransmissionDue(timeout: 1), 13)
        XCTAssertNil(sync.nextTransmission(now: 12.9, timeout: 1))
        XCTAssertNotNil(sync.nextTransmission(now: 13, timeout: 1))
        XCTAssertNil(sync.nextTransmission(now: 13.1, timeout: 1))
    }

    func testInputGoesOutBeforeAcksAndIsResentWhenDue() throws {
        var sync = MoshStateSync()
        sync.resetHeartbeat(now: 0)
        _ = sync.receive(instruction(old: 0, new: 4))
        sync.enqueue(MoshUserInput.encodeKeystroke(Data("x".utf8)))

        let first = try XCTUnwrap(sync.nextTransmission(now: 1, timeout: 0.5))
        XCTAssertEqual(first.newNum, 1)
        XCTAssertEqual(first.ackNum, 4, "input carries the ack too")
        XCTAssertNil(sync.nextTransmission(now: 1.1, timeout: 0.5), "the ack was already sent with the input")
        XCTAssertEqual(sync.nextTransmissionDue(timeout: 0.5), 1.5)

        let resend = try XCTUnwrap(sync.nextTransmission(now: 1.5, timeout: 0.5))
        XCTAssertEqual(resend.oldNum, 0)
        XCTAssertEqual(resend.newNum, 1)
        XCTAssertEqual(resend.diff, first.diff)
    }

    func testRetransmitTimeoutFollowsMoshBounds() {
        XCTAssertEqual(MoshStateSync.retransmitTimeout(smoothedRoundTrip: nil), 1.1, accuracy: 1e-9)
        XCTAssertEqual(MoshStateSync.retransmitTimeout(smoothedRoundTrip: 0.001), 0.15, accuracy: 1e-9)
        XCTAssertEqual(MoshStateSync.retransmitTimeout(smoothedRoundTrip: 0.2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MoshStateSync.retransmitTimeout(smoothedRoundTrip: 5), 1.1, accuracy: 1e-9)
    }
}
