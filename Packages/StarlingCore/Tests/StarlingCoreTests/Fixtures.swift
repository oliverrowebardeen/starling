import Foundation
import StarlingCore

enum Fixtures {
    static let alice = try! PeerID(bytes: Data(repeating: 0xAA, count: 32))
    static let bob = try! PeerID(bytes: Data(repeating: 0xBB, count: 32))
    static let mallory = try! PeerID(bytes: Data(repeating: 0xCC, count: 32))
    static let conversation = ConversationID(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
    static let messageID = MessageID(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
    /// 2026-10-02 19:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_967_600)

    static func terms() throws -> Terms {
        try Terms([
            .activity: .keywords([try Keyword("food")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1500)),
            .time: .slots([try TimeSlot(start: now, end: now.addingTimeInterval(3 * 3600))]),
        ])
    }

    static func proposalEnvelope(
        from sender: PeerID = alice,
        to recipient: PeerID = bob,
        sequence: UInt64 = 0,
        sentAt: Date = now,
        id: MessageID = messageID
    ) throws -> Envelope {
        try Envelope(
            id: id,
            conversation: conversation,
            sender: sender,
            recipient: recipient,
            sequence: sequence,
            sentAt: Timestamp(sentAt),
            body: .propose(try Proposal(round: 0, terms: terms()))
        )
    }
}
