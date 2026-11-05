import Foundation

/// The client half of mosh's state synchronization for user input, after mosh's
/// `TransportSender`.
///
/// Each state is the user's whole input history up to that point, so the diff between
/// two states is just the input in between (concatenated `UserMessage`s). mosh-server
/// drops any diff whose base state it doesn't hold, so diffs build on the newest state
/// the server acknowledged, or on a state sent so recently that it is presumed to have
/// arrived. If a state goes unacknowledged past the retransmit timeout, it is resent
/// from the acknowledged base. That is what recovers from a lost datagram.
///
/// `throwawayNum` is always the acknowledged state, which lets mosh-server discard
/// older states. Without it the server's state queue fills and, past 1,024 states, it
/// accepts just one new state every 15 seconds.
struct MoshTransportSender: Sendable {
    struct State: Sendable, Equatable {
        let num: UInt64
        /// Input since the previous state.
        var diff: Data
        /// When this state was last transmitted; nil while it is due to be sent.
        var sentAt: TimeInterval?
        /// Once a state may have reached the server its contents are fixed: the server
        /// drops a repeated state number, so later input must go in a new state.
        var wasSent = false
    }

    /// The newest state mosh-server acknowledged. It keeps this state, so diffs may build on it.
    private(set) var ackedNum: UInt64 = 0
    /// States newer than `ackedNum`, oldest first.
    private(set) var unacked: [State] = []

    var currentNum: UInt64 { unacked.last?.num ?? ackedNum }
    var hasUnacknowledgedInput: Bool { !unacked.isEmpty }

    /// Adds encoded user input. Input that arrives before the newest state was ever sent
    /// is folded into it, so a burst of keystrokes becomes one state.
    mutating func enqueue(_ userMessage: Data) {
        guard !userMessage.isEmpty else { return }
        if let lastIndex = unacked.indices.last, !unacked[lastIndex].wasSent {
            unacked[lastIndex].diff.append(userMessage)
        } else {
            unacked.append(State(num: currentNum + 1, diff: userMessage, sentAt: nil))
        }
    }

    /// Applies the `ackNum` of an authenticated server instruction. Acks for states this
    /// sender never created (including mosh's shutdown ack) are ignored.
    mutating func acknowledge(_ ackNum: UInt64) {
        guard ackNum > ackedNum, ackNum <= currentNum else { return }
        unacked.removeAll { $0.num <= ackNum }
        ackedNum = ackNum
    }

    /// When the newest state is due for a resend, if it has been sent and is unacknowledged.
    func retransmitDeadline(timeout: TimeInterval) -> TimeInterval? {
        guard let sentAt = unacked.last?.sentAt else { return nil }
        return sentAt + timeout
    }

    /// The instruction to transmit now, if any: unsent input, or a resend once the newest
    /// state has gone `timeout` without an acknowledgement. Marks the newest state as sent.
    mutating func nextInstruction(
        now: TimeInterval,
        timeout: TimeInterval,
        remoteAck: UInt64
    ) -> MoshTransportInstruction? {
        guard let newest = unacked.last else { return nil }
        if let sentAt = newest.sentAt, now - sentAt < timeout { return nil }

        // Like mosh, give the benefit of the doubt to states sent recently enough, starting
        // from the acknowledged one and stopping at the first that has gone stale. A resend
        // always starts from the acknowledged state.
        var baseIndex: Int?
        if newest.sentAt == nil {
            for index in unacked.indices.dropLast() {
                guard let sentAt = unacked[index].sentAt, now - sentAt < timeout else { break }
                baseIndex = index
            }
        }

        let firstIncluded = baseIndex.map { $0 + 1 } ?? 0
        var instruction = MoshTransportInstruction()
        instruction.oldNum = baseIndex.map { unacked[$0].num } ?? ackedNum
        instruction.newNum = newest.num
        instruction.ackNum = remoteAck
        instruction.throwawayNum = ackedNum
        instruction.diff = unacked[firstIncluded...].reduce(into: Data()) { $0.append($1.diff) }

        unacked[unacked.count - 1].sentAt = now
        unacked[unacked.count - 1].wasSent = true
        return instruction
    }

    /// Forgets transmission times so all unacknowledged input is resent from the
    /// acknowledged base right away, such as after the UDP socket was replaced.
    mutating func resendFromAcknowledgedState() {
        for index in unacked.indices {
            unacked[index].sentAt = nil
        }
        // Merge into one state: nothing past the acknowledged one can be presumed delivered.
        // The merged diff is the same input history, so the state number keeps its meaning.
        guard unacked.count > 1, let last = unacked.last else { return }
        let diff = unacked.reduce(into: Data()) { $0.append($1.diff) }
        unacked = [State(num: last.num, diff: diff, sentAt: nil, wasSent: last.wasSent)]
    }

    /// An instruction that carries only `remoteAck`, built on a state the server keeps.
    func acknowledgementInstruction(remoteAck: UInt64) -> MoshTransportInstruction {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = ackedNum
        instruction.newNum = ackedNum
        instruction.ackNum = remoteAck
        instruction.throwawayNum = ackedNum
        return instruction
    }

    /// The final client state, which asks mosh-server to exit. It also carries any input
    /// the server hasn't acknowledged yet.
    func shutdownInstruction(remoteAck: UInt64) -> MoshTransportInstruction {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = ackedNum
        instruction.newNum = MoshTransportSender.shutdownStateNum
        instruction.ackNum = remoteAck
        instruction.throwawayNum = ackedNum
        instruction.diff = unacked.reduce(into: Data()) { $0.append($1.diff) }
        return instruction
    }

    /// mosh marks the last state of a session with this number, in either direction.
    static let shutdownStateNum = UInt64.max
}
