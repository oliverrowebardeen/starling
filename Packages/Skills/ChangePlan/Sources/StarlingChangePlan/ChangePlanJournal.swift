import Foundation
import StarlingCore

// What must survive a restart for a change to reach every phone (ADR 0243):
// confirmations and leave notices not yet acknowledged, and what this phone
// already applied, so a resent one is acknowledged again. All typed values.

/// Confirmations on their way from the suggester to everyone who said yes.
public struct ConfirmationDelivery: Hashable, Sendable, Codable {
    /// The suggester's change.
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let planConversation: ConversationID
    /// Who is owed one, in plan order.
    public let order: [PeerID]
    /// Who has not acknowledged yet, and the offer their confirmation and
    /// acknowledgment name.
    public var pending: [PeerID: MessageID]
    /// When resending stops: the plan's end, or a bound for a plan without a time.
    public let until: Date
}

/// A confirmation this phone applied, kept so a resent one is acknowledged again.
public struct AppliedConfirmation: Hashable, Sendable, Codable {
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let planConversation: ConversationID
    public let suggester: PeerID
    public let offer: MessageID
    public let until: Date
}

/// Leave notices on their way to everyone else in the plan.
public struct LeaveDelivery: Hashable, Sendable, Codable {
    /// The owner's leave.
    public let interaction: InteractionID
    public let planConversation: ConversationID
    public let order: [PeerID]
    /// Who has not acknowledged yet, and every notice sent to each. Each
    /// attempt goes in a fresh conversation, so a friend can close it at once.
    public var pending: [PeerID: [MessageID]]
    public let until: Date
}

/// Someone this phone saw leave a plan, so a resent notice is acknowledged again.
public struct Departure: Hashable, Sendable, Codable {
    public let id: UUID
    public let planConversation: ConversationID
    public let peer: PeerID
    public let until: Date
}

public enum ChangePlanRecord: Hashable, Sendable, Codable {
    case confirming(ConfirmationDelivery)
    case applied(AppliedConfirmation)
    case leaving(LeaveDelivery)
    case departed(Departure)

    /// When it is no longer kept.
    public var until: Date {
        switch self {
        case .confirming(let delivery): delivery.until
        case .applied(let applied): applied.until
        case .leaving(let delivery): delivery.until
        case .departed(let departure): departure.until
        }
    }

    /// One record per key: a later save replaces it.
    public var key: UUID {
        switch self {
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

    public init(firstRetry: TimeInterval = 5, maxBackoff: TimeInterval = 300, minimumWindow: TimeInterval = 15 * 60,
                untimedWindow: TimeInterval = 24 * 3600) {
        self.firstRetry = firstRetry
        self.maxBackoff = maxBackoff
        self.minimumWindow = minimumWindow
        self.untimedWindow = untimedWindow
    }

    public static let standard = ResendSchedule()

    /// When resending for `plan` stops, from `now`.
    public func end(for plan: Plan, now: Date) -> Date {
        guard let end = plan.endsAt else { return now.addingTimeInterval(untimedWindow) }
        return max(end, now.addingTimeInterval(minimumWindow))
    }
}
