import Foundation
import StarlingCore

/// Wall time and timers, injectable so tests control expiry and run
/// retries in milliseconds.
public struct FindATimeClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = FindATimeClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// Tuning for one phone's Find a time service.
public struct FindATimeConfiguration: Hashable, Sendable {
    /// Length of every candidate time, in minutes.
    public var slotMinutes: Int
    /// The daily window candidates fall in when the owner did not say
    /// ("next week" means 9 to 9), in local minutes after midnight.
    public var dailyFrom: Int
    public var dailyTo: Int
    /// The range searched when the owner gave none, and the longest allowed.
    public var defaultRangeDays: Int
    public var maxRangeDays: Int
    /// Most times one query offers, and most an invitee answers about, at
    /// most `ProtocolLimits.maxCandidatesAnsweredPerIssue`. Bounds what a
    /// dishonest friend can probe with one request (ADRs 0019, 0221).
    public var maxCandidates: Int
    /// Longest candidate an invitee accepts in a query.
    public var maxCandidateMinutes: Int
    /// How long to wait for a reply before sending the same step again
    /// (delivery is best effort, ARCHITECTURE rule 5), and how many sends
    /// of one step to make.
    public var retryInterval: Duration
    public var maxAttempts: Int
    /// How long the starter waits for friends' answers, and then for their
    /// "That works", before deciding with what it has. Friends without a
    /// calendar answer only when their owner opens the app, and a request
    /// stays open for days (Compose sets no expiry chip for Find a time), so
    /// these are long. The answer deadline is also never later than halfway
    /// to the request's end or its last offered time, so there is always
    /// time to agree; the confirm deadline never passes the proposed time.
    public var answerWait: Duration
    public var confirmWait: Duration
    /// How long a friend's request stays open here, at most: never past the
    /// start of its last offered time.
    public var inviteeLifetime: Duration
    /// Open requests from friends, in total and from one friend, so a
    /// friend cannot flood Needs you.
    public var maxOpenInvitations: Int
    public var maxOpenInvitationsPerFriend: Int
    /// Proposals per interaction (a new one follows each pass in a group).
    public var maxRevisions: UInt32

    public init(
        slotMinutes: Int = 60,
        dailyFrom: Int = 9 * 60,
        dailyTo: Int = 21 * 60,
        defaultRangeDays: Int = 7,
        maxRangeDays: Int = 14,
        maxCandidates: Int = 16,
        maxCandidateMinutes: Int = 8 * 60,
        retryInterval: Duration = .seconds(5),
        maxAttempts: Int = 6,
        answerWait: Duration = .seconds(12 * 60 * 60),
        confirmWait: Duration = .seconds(12 * 60 * 60),
        inviteeLifetime: Duration = .seconds(7 * 24 * 60 * 60),
        maxOpenInvitations: Int = 32,
        maxOpenInvitationsPerFriend: Int = 4,
        maxRevisions: UInt32 = 8
    ) {
        // One query per conversation, so this also bounds the candidates an
        // invitee answers yes or no about (ADR 0019, decision 6).
        precondition(maxAttempts > 0 && maxCandidates > 0 && maxCandidates <= ProtocolLimits.maxCandidatesAnsweredPerIssue)
        precondition(maxRevisions > 0 && maxRevisions <= 16, "a proposal round must stay below ProtocolLimits.maxNegotiationRounds")
        precondition(maxRangeDays >= defaultRangeDays && maxRangeDays <= 14)
        self.slotMinutes = slotMinutes
        self.dailyFrom = dailyFrom
        self.dailyTo = dailyTo
        self.defaultRangeDays = defaultRangeDays
        self.maxRangeDays = maxRangeDays
        self.maxCandidates = maxCandidates
        self.maxCandidateMinutes = maxCandidateMinutes
        self.retryInterval = retryInterval
        self.maxAttempts = maxAttempts
        self.answerWait = answerWait
        self.confirmWait = confirmWait
        self.inviteeLifetime = inviteeLifetime
        self.maxOpenInvitations = maxOpenInvitations
        self.maxOpenInvitationsPerFriend = maxOpenInvitationsPerFriend
        self.maxRevisions = maxRevisions
    }
}

/// Why `start` or `answer` refused.
public enum FindATimeError: Error, Hashable, Sendable {
    /// The request is for another skill or an incompatible version.
    case wrongSkill
    /// The request asks for a send mode the skill does not offer (ADR 0020).
    case unsupportedMode
    /// An interaction with this ID or conversation is already running.
    case alreadyStarted
    /// The owner's range and daily window leave no time to offer.
    case noTimesInRange
    case unknownInteraction
    /// The answer does not fit what the interaction is waiting for.
    case notWaitingForThis
    /// A reply to a question other than the pending one.
    case staleQuestion(current: UInt32?)
    /// An acceptance of a proposal other than the current one.
    case staleProposal(current: UInt32?)
    /// A reply that is not a list of the offered times.
    case invalidReply
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
