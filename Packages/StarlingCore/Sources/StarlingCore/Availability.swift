import Foundation

public enum AvailabilitySourceKind: String, Hashable, Sendable, Codable {
    /// EventKit free/busy.
    case calendar
    /// What the owner said ("free tonight").
    case statedIntent
    /// One quick question to the owner when nothing else knows.
    case askOwner
}

public struct AvailabilityQuery: Hashable, Sendable {
    public let window: TimeSlot
    /// Smallest slot worth reporting, in minutes.
    public let granularityMinutes: Int

    public init(window: TimeSlot, granularityMinutes: Int = 30) throws {
        guard (5...1440).contains(granularityMinutes) else {
            throw ValidationError("AvailabilityQuery.granularity", "must be 5-1440 minutes")
        }
        self.window = window
        self.granularityMinutes = granularityMinutes
    }
}

/// A structured question the app renders for the owner, such as
/// "Mom's agent wants a time this weekend. Saturday afternoon?"
public struct OwnerQuestion: Hashable, Sendable {
    public let window: TimeSlot
    /// Slots to offer as one-tap answers.
    public let suggestions: [TimeSlot]

    public init(window: TimeSlot, suggestions: [TimeSlot]) {
        self.window = window
        self.suggestions = suggestions
    }
}

public enum AvailabilityAnswer: Hashable, Sendable {
    /// Free time inside the query window. Busy time is the complement, and
    /// event details never leave the source.
    case known(free: [TimeSlot])
    /// This source has nothing to say; try the next one.
    case unknown
    /// Only the owner can answer. The negotiation waits.
    case needsOwner(OwnerQuestion)
}

/// A pluggable availability backend. Calendar and non-calendar agents both
/// produce `[TimeSlot]`, which is what lets them interoperate (brief 2.3).
public protocol AvailabilitySource: Sendable {
    var kind: AvailabilitySourceKind { get }
    func availability(for query: AvailabilityQuery) async throws -> AvailabilityAnswer
}
