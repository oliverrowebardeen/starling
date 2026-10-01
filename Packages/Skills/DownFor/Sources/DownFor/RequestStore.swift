import Foundation
import StarlingCore

/// What the service keeps about one request so `restore(_:)` can resume it
/// after the app restarts. `Interaction` holds the lifecycle but not the
/// owner's rules, so this record holds those. Stays on the phone.
public struct DownForRequestRecord: Hashable, Sendable, Codable {
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let skill: SkillRef
    public let rules: OwnerRules
    public let audience: Audience
    public let mode: SendMode
    public let expiresAt: Timestamp
    public let participants: [PeerID]
    public let inputs: [Artifact]
    public let chainedFrom: ConversationID?
    /// PSI runs debited per friend, kept with the record so a restart does
    /// not refill a friend's run budget. Nil in a record from before it.
    public internal(set) var runDebits: [PeerID: Int]?

    /// The record of an invitee's card: the friend's invitation, which
    /// lasts until the plan it names starts. The invitee's rules are not
    /// involved; the owner decides by looking at the card.
    init(invitation interaction: InteractionID, conversation: ConversationID, from starter: PeerID, until expiresAt: Timestamp, chainedFrom: ConversationID?) {
        self.interaction = interaction
        self.conversation = conversation
        skill = DownFor.ref
        rules = .empty
        audience = .picked([starter])
        mode = .invite
        self.expiresAt = expiresAt
        participants = [starter]
        inputs = []
        self.chainedFrom = chainedFrom
    }

    init(_ request: SkillRequest) {
        interaction = request.interaction
        conversation = request.conversation
        skill = request.intent.skill
        rules = request.intent.rules
        audience = request.intent.audience
        mode = request.intent.mode
        expiresAt = request.intent.expiresAt
        participants = request.participants
        inputs = request.inputs
        chainedFrom = request.chainedFrom
    }
}

/// Where the service keeps request records. The app supplies a persistent
/// one; `InMemoryDownForRequestStore` is the default and the test double.
public protocol DownForRequestStore: Sendable {
    func save(_ record: DownForRequestRecord) async throws
    func record(for interaction: InteractionID) async throws -> DownForRequestRecord?
    func remove(_ interaction: InteractionID) async throws
}

public actor InMemoryDownForRequestStore: DownForRequestStore {
    private var records: [InteractionID: DownForRequestRecord] = [:]

    public init() {}

    public func save(_ record: DownForRequestRecord) async throws { records[record.interaction] = record }
    public func record(for interaction: InteractionID) async throws -> DownForRequestRecord? { records[interaction] }
    public func remove(_ interaction: InteractionID) async throws { records[interaction] = nil }
}
