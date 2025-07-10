import Foundation

/// Keeps an in-memory count of how many times we’ve relayed a given message ID.
public final class HopLogger {

    private var counts: [UUID: Int] = [:]
    private let lock = NSLock()          // thread-safe for future use

    public init() {}

    /// Call this every time a packet with `messageID` passes through this node.
    public func recordHop(messageID: UUID) {
        lock.lock()
        counts[messageID, default: 0] += 1
        lock.unlock()
    }

    /// Returns nil if we’ve never seen that message.
    public func hopCount(for messageID: UUID) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return counts[messageID]
    }

    /// Clears the internal map (handy in tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        counts.removeAll()
    }
}
