import Foundation

/// UIKit can deliver one hardware key twice: as a press, which the terminal sends right
/// away, and again as inserted text. This matches each inserted text to an unmatched
/// press of the same characters so the key is sent once. Each press absorbs at most one
/// insertion, in order, so fast typing (several presses before their text arrives) and
/// a busy main thread (text arriving late) don't double characters.
struct PressedKeyTextFilter {
    /// How long a press waits for its inserted text. Typing the same key again is a new
    /// press, so this only needs to outlast main-thread delays.
    static let window: TimeInterval = 0.5

    private var unmatchedPresses: [(data: Data, time: TimeInterval)] = []

    mutating func recordPress(_ data: Data, at time: TimeInterval) {
        prune(now: time)
        unmatchedPresses.append((data, time))
    }

    /// True when the text repeats a press already sent; that press is then matched.
    mutating func suppressesInsertedText(_ data: Data, at time: TimeInterval) -> Bool {
        prune(now: time)
        guard let index = unmatchedPresses.firstIndex(where: { $0.data == data }) else { return false }
        unmatchedPresses.remove(at: index)
        return true
    }

    private mutating func prune(now: TimeInterval) {
        unmatchedPresses.removeAll { now - $0.time > Self.window }
    }
}
