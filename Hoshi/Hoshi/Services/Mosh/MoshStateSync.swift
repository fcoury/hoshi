import Foundation

/// The protocol state of one mosh-server session, with no I/O: which server states
/// apply, what to transmit and when, and the shutdown handshake. `MoshSession` owns
/// the sockets, tasks and recovery around it, and starts a new value for each
/// mosh-server it connects to. The value survives socket replacement during recovery.
struct MoshStateSync: Sendable {
    /// mosh marks the last state of a session with this number, in either direction.
    static let shutdownStateNum = MoshTransportSender.shutdownStateNum
    /// Keepalive interval for the NAT mapping and our acknowledgements, as in mosh.
    static let heartbeatInterval: TimeInterval = 3
    /// mosh's blank frame: a full terminal reset (RIS), so nothing an earlier session in
    /// this view left behind (colors, modes, alternate screen) leaks into mosh's diffs,
    /// then scrolling region, attributes and screen as mosh's own clear sets them.
    static let blankScreen = Data("\u{1b}c\u{1b}[r\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8)

    enum Receipt: Equatable {
        /// The diff builds on our state, so its output goes to the terminal.
        case applied
        /// A state we already hold; mosh-server resends until it hears our ack.
        case stale
        /// Built on a state we never reached, so it is dropped until the server resends
        /// from our state.
        case unknownBase
    }

    /// User input not yet acknowledged by mosh-server.
    private(set) var sender = MoshTransportSender()
    /// The newest server state applied to the terminal.
    private(set) var remoteStateNum: UInt64 = 0
    /// Set when mosh-server acknowledges our shutdown state.
    private(set) var clientShutdownAcknowledged = false
    /// Set by every server instruction, so the ack goes out right away instead of with
    /// the next heartbeat; that lets mosh-server send its next diff from our state.
    private(set) var needsImmediateAck = false
    private(set) var lastTransmitAt: TimeInterval = 0
    /// mosh-server draws its first frame as a diff against a blank screen.
    private var terminalNeedsBlankScreen = true

    /// Set once the server's final state was applied: its shell exited.
    var remoteEnded: Bool { remoteStateNum == Self.shutdownStateNum }

    // MARK: Receiving

    /// Takes the server's acknowledgement and decides whether the instruction's diff
    /// applies. Only a diff from exactly our state may be shown: mosh frames are diffs.
    mutating func receive(_ instruction: MoshTransportInstruction) -> Receipt {
        // Every authenticated instruction carries the server's ack, duplicates included.
        sender.acknowledge(instruction.ackNum)
        if instruction.ackNum == Self.shutdownStateNum {
            clientShutdownAcknowledged = true
        }
        needsImmediateAck = true

        guard instruction.newNum > remoteStateNum else { return .stale }
        guard instruction.oldNum == remoteStateNum else { return .unknownBase }
        remoteStateNum = instruction.newNum
        return .applied
    }

    /// Host bytes ready for the terminal. The first bytes of a session start from a blank
    /// screen; after that each frame builds on the last (mosh repaints fully on resize).
    mutating func terminalBytes(_ hostBytes: Data) -> Data {
        guard terminalNeedsBlankScreen, !hostBytes.isEmpty else { return hostBytes }
        terminalNeedsBlankScreen = false
        return Self.blankScreen + hostBytes
    }

    // MARK: Sending

    mutating func enqueue(_ userMessage: Data) {
        sender.enqueue(userMessage)
    }

    /// After the socket was replaced: whatever was in flight on the old one may be gone.
    mutating func resendUnacknowledgedInput() {
        sender.resendFromAcknowledgedState()
    }

    /// How long a sent state may go unacknowledged before it is resent from the
    /// acknowledged base: mosh's RTO (bounded to 50 ms...1 s) plus its 100 ms ack delay.
    static func retransmitTimeout(smoothedRoundTrip: TimeInterval?) -> TimeInterval {
        min(1, max(0.05, (smoothedRoundTrip ?? 1) * 2)) + 0.1
    }

    /// Starts the heartbeat clock, such as when a transmit loop starts.
    mutating func resetHeartbeat(now: TimeInterval) {
        lastTransmitAt = now
    }

    /// The instruction to send now, if any: new or resent input, else a quick ack or a
    /// heartbeat. Assumes it is sent.
    mutating func nextTransmission(now: TimeInterval, timeout: TimeInterval) -> MoshTransportInstruction? {
        if let instruction = sender.nextInstruction(now: now, timeout: timeout, remoteAck: remoteStateNum) {
            needsImmediateAck = false
            lastTransmitAt = now
            return instruction
        }
        guard needsImmediateAck || now - lastTransmitAt >= Self.heartbeatInterval else { return nil }
        needsImmediateAck = false
        lastTransmitAt = now
        return acknowledgementInstruction()
    }

    /// When `nextTransmission` will next have something to send, unless woken earlier.
    func nextTransmissionDue(timeout: TimeInterval) -> TimeInterval {
        let heartbeat = lastTransmitAt + Self.heartbeatInterval
        guard let resend = sender.retransmitDeadline(timeout: timeout) else { return heartbeat }
        return min(heartbeat, resend)
    }

    /// Carries only our acknowledgement of the server's state.
    func acknowledgementInstruction() -> MoshTransportInstruction {
        sender.acknowledgementInstruction(remoteAck: remoteStateNum)
    }

    /// The final client state, which asks mosh-server to exit.
    func shutdownInstruction() -> MoshTransportInstruction {
        sender.shutdownInstruction(remoteAck: remoteStateNum)
    }
}
