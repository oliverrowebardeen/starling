import Foundation
import StarlingCore

// What must survive a restart for a change to reach every phone (ADR 0243):
// confirmations and leave notices not yet acknowledged, and what this phone
// already applied, so a resent one is acknowledged again. All typed values.

/// A yes this phone gave, kept from before it is sent until the change
/// applies or delivery ends, so a confirmation that comes late, or after a
/// restart, still applies (review of PR #111, finding 1).
public struct AcceptedOffer: Hashable, Sendable, Codable {
    /// The card.
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let planConversation: ConversationID
    /// A friend being added, whose card will hold the plan.
    public let joining: Bool
    public let suggester: PeerID
    public let offer: MessageID
    /// The plan the suggestion changes (nil for a friend being added), and the plan it agreed.
    public let basis: Plan?
    public let proposed: Plan
    /// Where the plan lives on this phone; nil for a friend being added.
    public let planInteraction: InteractionID?
    /// The offer's decision window: the hold on the plan ends a grace after
    /// it (final review of PR #111, finding 3).
    public let deadline: Date?
    public let until: Date
}

/// A suggestion still asking, with the offers sent so far, so that after a
/// restart everyone asked can be told it is withdrawn (finding 3).
public struct OpenSuggestion: Hashable, Sendable, Codable {
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let planConversation: ConversationID
    public let asked: [PeerID]
    public var offers: [PeerID: MessageID]
    /// The window's end plus the grace a yes holds the plan for.
    public let until: Date
}

/// Withdrawals of a suggestion that ended without a change, resent until
/// each person acknowledges them, so no card that said yes holds the plan
/// for longer than it must (finding 3). Each attempt goes in a fresh
/// conversation and names the offer it withdraws.
public struct WithdrawalDelivery: Hashable, Sendable, Codable {
    public let interaction: InteractionID
    public let planConversation: ConversationID
    public var order: [PeerID]
    /// Who has not acknowledged yet, and the offer each withdrawal names.
    public var pending: [PeerID: MessageID]
    public let until: Date
}

/// Confirmations on their way from the suggester to everyone who said yes,
/// with the agreed plan, journaled before it is published so a restart
/// can finish the commit (finding 3).
public struct ConfirmationDelivery: Hashable, Sendable, Codable {
    /// The suggester's change.
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let planConversation: ConversationID
    /// The agreed plan, and the interaction that holds the plan here.
    public let plan: Plan
    public let planInteraction: InteractionID?
    /// Who is owed one, in plan order.
    public let order: [PeerID]
    /// Who has not acknowledged yet, and the offer their confirmation and
    /// acknowledgment name.
    public var pending: [PeerID: MessageID]
    /// When resending stops: the plan's end, or a bound for a plan without a time.
    public let until: Date
}

/// A confirmation this phone applied, with the plan it applied, kept so a
/// resent one is acknowledged again, and so a restart can replay the
/// update if it never became durable (finding 3).
public struct AppliedConfirmation: Hashable, Sendable, Codable {
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let planConversation: ConversationID
    public let suggester: PeerID
    public let offer: MessageID
    public let plan: Plan
    /// Where the plan lives; nil when the card itself holds it (a friend added).
    public let planInteraction: InteractionID?
    public let basisRevision: UInt32
    public let until: Date
}

/// Leave notices on their way to everyone else in the plan.
public struct LeaveDelivery: Hashable, Sendable, Codable {
    /// The owner's leave.
    public let interaction: InteractionID
    public let planConversation: ConversationID
    /// The plan revision the owner left at, which every notice names.
    public let revision: UInt32
    /// This departure, the same on every attempt to everyone, so a friend
    /// tells a resent notice from a later departure by the same person
    /// (review of PR #111). Each attempt goes in a fresh conversation, so a
    /// friend can close it at once.
    public let departure: MessageID
    public let order: [PeerID]
    /// Who has not acknowledged it yet.
    public var pending: Set<PeerID>
    public let until: Date
}

/// Someone this phone saw leave a plan, so a resent notice is acknowledged again.
public struct Departure: Hashable, Sendable, Codable {
    public let id: UUID
    /// The departure's own ID, which every attempt of its notice names.
    public let departure: MessageID
    public let planConversation: ConversationID
    public let peer: PeerID
    /// The revision it applied to, so a restart replays it only onto that
    /// plan (never onto one they were added back to).
    public let revision: UInt32
    public let until: Date
}

public enum ChangePlanRecord: Hashable, Sendable, Codable {
    case accepted(AcceptedOffer)
    case asking(OpenSuggestion)
    case withdrawing(WithdrawalDelivery)
    case confirming(ConfirmationDelivery)
    case applied(AppliedConfirmation)
    case leaving(LeaveDelivery)
    case departed(Departure)

    /// When it is no longer kept.
    public var until: Date {
        switch self {
        case .accepted(let offer): offer.until
        case .asking(let suggestion): suggestion.until
        case .withdrawing(let delivery): delivery.until
        case .confirming(let delivery): delivery.until
        case .applied(let applied): applied.until
        case .leaving(let delivery): delivery.until
        case .departed(let departure): departure.until
        }
    }

    /// One record per key: a later save replaces it.
    public var key: UUID {
        switch self {
        case .accepted(let offer): offer.interaction.rawValue
        case .asking(let suggestion): suggestion.interaction.rawValue
        case .withdrawing(let delivery): delivery.interaction.rawValue
        case .confirming(let delivery): delivery.interaction.rawValue
        case .applied(let applied): applied.interaction.rawValue
        case .leaving(let delivery): delivery.interaction.rawValue
        case .departed(let departure): departure.id
        }
    }
}

/// Durable storage for `ChangePlanRecord`s. The app keeps it on disk (lane
/// A); `InMemoryChangePlanJournal` is for tests and survives a service, not
/// the app.
public protocol ChangePlanJournal: Sendable {
    /// Adds the record, or replaces the one with the same key. Durable
    /// before it returns.
    func save(_ record: ChangePlanRecord) async throws
    func remove(_ key: UUID) async throws
    func records() async throws -> [ChangePlanRecord]
}

public actor InMemoryChangePlanJournal: ChangePlanJournal {
    private var stored: [UUID: ChangePlanRecord] = [:]
    private var order: [UUID] = []

    public init() {}

    public func save(_ record: ChangePlanRecord) async throws {
        if stored.updateValue(record, forKey: record.key) == nil { order.append(record.key) }
    }

    public func remove(_ key: UUID) async throws {
        stored[key] = nil
        order.removeAll { $0 == key }
    }

    public func records() async throws -> [ChangePlanRecord] { order.compactMap { stored[$0] } }
}

/// How confirmations and leave notices are resent until acknowledged: at
/// once, then after waits that start at `firstRetry` and double up to
/// `maxBackoff`, like Down for's delivery schedule, until the plan's time
/// has passed (at least `minimumWindow` from the first send), or for
/// `untimedWindow` when the plan has no time.
public struct ResendSchedule: Hashable, Sendable {
    public var firstRetry: TimeInterval
    public var maxBackoff: TimeInterval
    public var minimumWindow: TimeInterval
    public var untimedWindow: TimeInterval
    /// How long after a suggestion's window a yes still holds the plan for
    /// its confirmation, and withdrawals are resent (final review of PR
    /// #111, finding 3). The suggester commits only within the window, so
    /// this covers delivery only.
    public var holdGrace: TimeInterval

    public init(firstRetry: TimeInterval = 5, maxBackoff: TimeInterval = 300, minimumWindow: TimeInterval = 15 * 60,
                untimedWindow: TimeInterval = 24 * 3600, holdGrace: TimeInterval = 15 * 60) {
        self.firstRetry = firstRetry
        self.maxBackoff = maxBackoff
        self.minimumWindow = minimumWindow
        self.untimedWindow = untimedWindow
        self.holdGrace = holdGrace
    }

    public static let standard = ResendSchedule()

    /// When resending for `plan` stops, from `now`.
    public func end(for plan: Plan, now: Date) -> Date {
        guard let end = plan.endsAt else { return now.addingTimeInterval(untimedWindow) }
        return max(end, now.addingTimeInterval(minimumWindow))
    }
}
