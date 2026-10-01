import Foundation

// What this phone has already told each friend in each conversation, and
// which conversations are over (ADR 0021). Lanes B, C, and D each kept
// their own version in skill state, and each leaked at a different edge: a
// 24-hour window, a bounded cache, a replaced run, a relaunch. One ledger,
// persisted by the app and enforced by `Outbox`, replaces them.

/// A persistent, fail-closed record of answered candidates and retired
/// conversations. The app persists it; `StarlingFakes.InMemoryConversationLedger`
/// is the double. Every method that changes it must be durable before it
/// returns, and must throw rather than report success it cannot keep.
public protocol ConversationLedger: Sendable {
    /// Whether `conversation` has ended on this phone. Nothing is ever sent
    /// in a retired conversation again, and a skill opens nothing for one.
    func isRetired(_ conversation: ConversationID) async throws -> Bool
    /// Ends `conversation` for good: on every ending, withdrawal included.
    func retire(_ conversation: ConversationID) async throws
    /// Reserves answers about `candidates` (one candidate each, see
    /// `IssueValue.candidates`) of `issue` to `peer` in `conversation`.
    /// Returns false, reserving nothing, if the conversation is retired or
    /// the distinct candidates answered so far plus these would exceed
    /// `ProtocolLimits.maxCandidatesAnsweredPerIssue`. Asking again about a
    /// candidate already reserved costs nothing.
    func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool
}

extension IssueValue {
    /// The value split into single candidates, for counting what a yes/no
    /// answer covers: each keyword, slot, place, or peer on its own, and a
    /// scalar as itself.
    public var candidates: [IssueValue] {
        switch self {
        case .keywords(let list): list.map { .keywords([$0]) }
        case .slots(let list): list.map { .slots([$0]) }
        case .places(let list): list.map { .places([$0]) }
        case .peers(let list): list.map { .peers([$0]) }
        case .amount, .flag, .count: [self]
        }
    }
}
