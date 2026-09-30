import Foundation

// The Down? feature as the app sees it. Lane F implements `DownService` in
// StarlingNegotiation; lane H builds the Down screen against it (and against
// `StarlingFakes.ScriptedDownService` until F lands). How agents negotiate
// behind it is F's design; see ARCHITECTURE.md section 7 for the v1 flow.

/// How keen the owner is. A "maybe" is revealed to a friend only if that
/// friend is also interested (brief 2.6).
public enum DownLevel: String, Hashable, Sendable, Codable {
    case down, maybe
}

/// What the owner wants right now, after reviewing the interpreted rules
/// ("free tonight, want food, under $15").
public struct DownIntent: Hashable, Sendable, Codable {
    public let rules: OwnerRules
    public let level: DownLevel
    public let expiresAt: Timestamp

    public init(rules: OwnerRules, level: DownLevel, expiresAt: Timestamp) {
        self.rules = rules
        self.level = level
        self.expiresAt = expiresAt
    }
}

/// A mutual match with one paired friend: the only thing that may trigger a
/// notification (match-before-notify, brief 2.6).
public struct DownMatch: Hashable, Sendable {
    public let peer: PeerID
    /// The plan both agents agreed on.
    public let terms: Terms
    /// True when both said "down"; false when at least one side was "maybe"
    /// (revealed only because interest was mutual).
    public let bothDown: Bool

    public init(peer: PeerID, terms: Terms, bothDown: Bool) {
        self.peer = peer
        self.terms = terms
        self.bothDown = bothDown
    }
}

public enum DownEndReason: String, Hashable, Sendable, Codable {
    case expired, withdrawn, failed
}

public enum DownEvent: Hashable, Sendable {
    /// Checking with this many reachable paired friends.
    case checking(friends: Int)
    case matched(DownMatch)
    case ended(DownEndReason)
}

/// Publishes the owner's intent to paired friends' agents and reports
/// mutual matches. One-sided interest must never produce an event on either
/// phone.
public protocol DownService: Sendable {
    /// Single consumer.
    var events: AsyncStream<DownEvent> { get }
    /// Starts (or replaces) the owner's current intent.
    func setIntent(_ intent: DownIntent) async throws
    /// Withdraws the current intent; friends learn nothing beyond "no match".
    func clearIntent() async
}
