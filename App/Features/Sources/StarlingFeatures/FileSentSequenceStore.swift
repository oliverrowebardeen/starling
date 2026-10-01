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
/// Bounded: the `maxConversations` most recently used are kept. A dropped
/// conversation restarts at the clock in milliseconds, which is above
/// anything sent earlier unless the clock moved back since.
public final class FileSentSequenceStore: SentSequenceStore, @unchecked Sendable {
    public static let maxConversations = 1_024

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
    private let maxConversations: Int
    private var document: Document
    private var clock: Int64 = 0
    /// Where an unreadable file was moved, if one was.
    public private(set) var quarantined: URL?

    public init(file: JSONFile, maxConversations: Int = FileSentSequenceStore.maxConversations) {
        self.file = file
        self.maxConversations = maxConversations
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
            if next.sent.count > maxConversations {
                for old in next.sent.sorted(by: { $0.value.used < $1.value.used }).prefix(next.sent.count - maxConversations) {
                    next.sent[old.key] = nil
                }
            }
            // Written first: memory never claims a number the disk does not.
            try file.write(next)
            document = next
        }
    }
}
