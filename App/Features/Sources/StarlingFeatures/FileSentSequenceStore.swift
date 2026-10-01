import Foundation
import StarlingCore

/// Remembers the highest sequence number this phone sent in each
/// conversation, across launches (Core v2.1, `SentSequenceStore`), in
/// `Application Support/Starling/sent-sequences.json` (ADR 0200's helper).
///
/// `Outbox` calls it synchronously with no suspension between numbering
/// and sending, so it holds a lock and writes the file before returning: a
/// number is on disk before the envelope leaves, or the send stops.
///
/// Bounded by what can resume, never by a count: at launch the app keeps
/// every conversation of an interaction that is live or ended within the
/// 24-hour restore window (`retainOnly`), and drops the rest, link-level
/// hello traffic included. While the app runs nothing is evicted, so a
/// live conversation's number is never forgotten (re-review of PR #54).
public final class FileSentSequenceStore: RetainingSentSequenceStore, @unchecked Sendable {
    struct Document: Codable {
        var version = 1
        /// Conversation UUID to highest sequence sent, plus when it was last
        /// used, for pruning.
        var sent: [String: Entry] = [:]
    }

    struct Entry: Codable {
        var highest: UInt64
        var used: Int64
    }

    private let lock = NSLock()
    private let file: JSONFile
    private var document: Document
    private var clock: Int64 = 0
    /// Where an unreadable file was moved, if one was.
    public private(set) var quarantined: URL?

    public init(file: JSONFile) {
        self.file = file
        do {
            document = try file.read(Document.self) ?? Document()
        } catch {
            quarantined = try? file.quarantine()
            document = Document()
        }
        clock = document.sent.values.map(\.used).max() ?? 0
    }

    public static func standard() throws -> FileSentSequenceStore {
        FileSentSequenceStore(file: try .standard("sent-sequences.json"))
    }

    public func highestSent(in conversation: ConversationID) -> UInt64? {
        lock.withLock { document.sent[conversation.rawValue.uuidString]?.highest }
    }

    public func recordSent(_ sequence: UInt64, in conversation: ConversationID) throws {
        try lock.withLock {
            var next = document
            clock += 1
            let key = conversation.rawValue.uuidString
            next.sent[key] = Entry(highest: max(next.sent[key]?.highest ?? 0, sequence), used: clock)
            // Written first: memory never claims a number the disk does not.
            try file.write(next)
            document = next
        }
    }
}

extension FileSentSequenceStore {
    public var conversationCount: Int { lock.withLock { document.sent.count } }

    /// Keeps only `conversations`, the ones that can still resume, and
    /// forgets every other number.
    public func retainOnly(_ conversations: Set<ConversationID>) throws {
        try lock.withLock {
            let keep = Set(conversations.map(\.rawValue.uuidString))
            var next = document
            next.sent = next.sent.filter { keep.contains($0.key) }
            guard next.sent.count != document.sent.count else { return }
            try file.write(next)
            document = next
        }
    }
}

/// A sent-sequence store the app can prune at launch to the conversations
/// that can still resume.
public protocol RetainingSentSequenceStore: SentSequenceStore {
    func retainOnly(_ conversations: Set<ConversationID>) throws
}
