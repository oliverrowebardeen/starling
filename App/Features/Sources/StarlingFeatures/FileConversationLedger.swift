import Foundation
import StarlingCore

/// The phone's `ConversationLedger` (ADR 0021, decision 6): retired
/// conversations and the distinct candidates answered per friend,
/// conversation, and issue, in `Application Support/Starling/ledger.json`
/// (ADR 0200's helper).
///
/// - Fail-closed: a file that exists but cannot be read makes every call
///   throw, and so does a failed write. It never reads as empty after a
///   failure, so Outbox stops every send instead of forgetting a limit or
///   a withdrawal.
/// - Every change is written before the call returns, and the cache
///   changes only after the write succeeds.
/// - Never pruned: a retired conversation stays retired for the life of
///   the install.
public actor FileConversationLedger: ConversationLedger {
    public struct Unreadable: Error, Hashable, Sendable {}

    struct Document: Codable, Equatable {
        var version = 1
        var retired: Set<String> = []
        /// "conversation UUID/peer hex/issue" to the candidates answered,
        /// each as its canonical JSON.
        var answered: [String: Set<String>] = [:]
    }

    private let file: JSONFile
    private var cache: Document?
    private var failed = false

    public init(file: JSONFile) {
        self.file = file
    }

    public static func standard() throws -> FileConversationLedger {
        FileConversationLedger(file: try .standard("ledger.json"))
    }

    public func isRetired(_ conversation: ConversationID) async throws -> Bool {
        try loaded().retired.contains(conversation.rawValue.uuidString)
    }

    public func retire(_ conversation: ConversationID) async throws {
        var next = try loaded()
        guard next.retired.insert(conversation.rawValue.uuidString).inserted else { return }
        try commit(next)
    }

    public func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool {
        var next = try loaded()
        guard !next.retired.contains(conversation.rawValue.uuidString) else { return false }
        let key = "\(conversation.rawValue.uuidString)/\(peer.hex)/\(issue.rawValue)"
        let existing = next.answered[key] ?? []
        let combined = existing.union(try candidates.map(Self.canonical))
        guard combined.count <= ProtocolLimits.maxCandidatesAnsweredPerIssue else { return false }
        guard combined != existing else { return true }
        next.answered[key] = combined
        try commit(next)
        return true
    }

    private func loaded() throws -> Document {
        if failed { throw Unreadable() }
        if let cache { return cache }
        do {
            let document = try file.read(Document.self) ?? Document()
            cache = document
            return document
        } catch {
            failed = true
            throw Unreadable()
        }
    }

    private func commit(_ next: Document) throws {
        try file.write(next)
        cache = next
    }

    static func canonical(_ value: IssueValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Stands in when the ledger's file cannot even be located: every call
/// throws, so Outbox sends nothing rather than sending without a ledger.
public struct UnavailableConversationLedger: ConversationLedger {
    public struct Unavailable: Error {}
    public init() {}
    public func isRetired(_ conversation: ConversationID) async throws -> Bool { throw Unavailable() }
    public func retire(_ conversation: ConversationID) async throws { throw Unavailable() }
    public func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool { throw Unavailable() }
}
