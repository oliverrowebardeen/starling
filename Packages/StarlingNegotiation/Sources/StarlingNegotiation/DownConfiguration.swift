import Foundation

/// Wall time and timers for the Down service, injectable so tests control
/// expiry and run retries in milliseconds.
public struct DownClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = DownClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// Tuning for one device's Down service. Values that both phones must agree
/// on (slot length, set size) are protocol constants in `DownTokenSet`, not here.
public struct DownConfiguration: Hashable, Sendable {
    /// How long to wait for a reply before sending the same step again.
    /// Delivery is best effort (ARCHITECTURE rule 5), and the peer's model may
    /// take a few seconds per call, so this is generous.
    public var retryInterval: Duration
    /// Sends of one step (the first plus retries) before the conversation ends
    /// silently. A step times out after `retryInterval * maxAttempts`.
    public var maxAttempts: Int
    /// Offers per conversation, counting the opening proposal. Well below
    /// `ProtocolLimits.maxNegotiationRounds` so a peer cannot keep the model busy.
    public var maxRounds: UInt16
    /// Longest plan the opening proposal suggests.
    public var maxPlanMinutes: Int64
    /// PSI runs with one friend per intent, in either role. Each run reveals
    /// the overlap with at most `DownTokenSet.setSize` of that friend's slots,
    /// so repeated runs would let a dishonest friend map all of our free time.
    public var maxRunsPerPeer: Int
    /// Finished conversations remembered so late duplicates get the same reply.
    public var maxFinishedConversations: Int

    public init(
        retryInterval: Duration = .seconds(5),
        maxAttempts: Int = 6,
        maxRounds: UInt16 = 4,
        maxPlanMinutes: Int64 = 120,
        maxRunsPerPeer: Int = 3,
        maxFinishedConversations: Int = 64
    ) {
        precondition(maxAttempts > 0 && maxRounds > 0 && maxRounds <= 16 && maxPlanMinutes >= DownTokenSet.slotMinutes)
        self.retryInterval = retryInterval
        self.maxAttempts = maxAttempts
        self.maxRounds = maxRounds
        self.maxPlanMinutes = maxPlanMinutes
        self.maxRunsPerPeer = maxRunsPerPeer
        self.maxFinishedConversations = maxFinishedConversations
    }
}
