import Foundation

/// Wall time and timers, injectable so tests control expiry and run retries
/// in milliseconds.
public struct SkillClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = SkillClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// Tuning for one device's Down for... service. Values both phones must
/// agree on (slot length, set size, token namespace) are protocol constants,
/// not here.
public struct DownForConfiguration: Hashable, Sendable {
    /// How long to wait for an agent's reply before sending the same step
    /// again. Delivery is best effort (ARCHITECTURE rule 5).
    public var retryInterval: Duration
    /// Sends of one automatic step (the first plus retries) before that
    /// friend's run ends silently.
    public var maxAttempts: Int
    /// Longest plan the starter proposes.
    public var maxPlanMinutes: Int64
    /// PSI runs with one friend per request, in either role, so repeated
    /// runs cannot map all of the owner's free time (ADR 0120).
    public var maxRunsPerPeer: Int
    /// How long a proposal waits for people to tap I'm in. Friends who have
    /// not answered by then are left out, and the rest get a new proposal.
    public var ownerWindow: Duration
    /// Steps that wait on people resend with a doubling interval, up to this.
    public var maxBackoff: Duration
    /// Finished conversations remembered so a late retry gets the same reply.
    public var maxFinishedRuns: Int

    public init(
        retryInterval: Duration = .seconds(5),
        maxAttempts: Int = 6,
        maxPlanMinutes: Int64 = 120,
        maxRunsPerPeer: Int = 3,
        ownerWindow: Duration = .seconds(15 * 60),
        maxBackoff: Duration = .seconds(60),
        maxFinishedRuns: Int = 64
    ) {
        precondition(maxAttempts > 0 && maxPlanMinutes >= 30 && maxRunsPerPeer > 0 && ownerWindow > .zero && maxBackoff >= retryInterval)
        self.retryInterval = retryInterval
        self.maxAttempts = maxAttempts
        self.maxPlanMinutes = maxPlanMinutes
        self.maxRunsPerPeer = maxRunsPerPeer
        self.ownerWindow = ownerWindow
        self.maxBackoff = maxBackoff
        self.maxFinishedRuns = maxFinishedRuns
    }
}

public enum DownForError: Error, Hashable, Sendable {
    /// The request names another skill, or an incompatible version.
    case wrongSkill
    /// The request's expiry is not in the future.
    case expired
    /// The owner's rules leave no free half-hour before the request expires.
    case noAvailableTime
    /// The request has no activity: Down for... always has one (ADR 0017).
    case noActivity
    case noParticipants
    case alreadyStarted
    case unknownInteraction
    /// An answer for a proposal that is not the current one.
    case staleProposal(current: UInt32?)
    /// The interaction is not waiting for this answer right now, for
    /// example while a consent sheet is open.
    case notWaitingForOwner
    /// Down for... never asks its owner a question.
    case unsupportedAnswer
}
