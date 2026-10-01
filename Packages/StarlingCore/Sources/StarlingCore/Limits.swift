/// Hard limits for protocol version 0.
///
/// Every value a peer can send is bounded. Types enforce these limits in their
/// validating initializers, and `Decodable` conformances call those
/// initializers, so malformed or oversized input fails at decode time instead
/// of reaching negotiation logic or a model prompt.
public enum ProtocolLimits {
    /// Largest frame any transport carries. The LocalP2P framer uses a 16-bit
    /// length, so this must stay below 65,535 (ADR 0004).
    public static let maxFrameBytes = 60 * 1024
    /// Largest encoded envelope. Leaves room below `maxFrameBytes` for the
    /// secure channel's framing and authentication tags (ADR 0003).
    public static let maxEnvelopeBytes = 56 * 1024

    public static let maxKeywordCharacters = 32
    public static let maxKeywordsPerValue = 16
    public static let maxSlotsPerValue = 64
    public static let maxIssuesPerTerms = 8
    public static let maxIssueKeyCharacters = 32
    /// Longest a single `TimeSlot` may span, in minutes (14 days).
    public static let maxSlotMinutes: Int64 = 14 * 24 * 60
    public static let maxMoneyMinorUnits: Int64 = 1_000_000_000
    public static let maxCount = 1_000
    public static let maxNegotiationRounds: UInt16 = 16
    public static let maxProtocolVersionsAdvertised = 4
    public static let maxCapabilities = 16
    /// Skills one agent card may advertise (ADR 0010).
    public static let maxSkillsAdvertised = 32
    /// A venue name's length, in characters (ADR 0012).
    public static let maxPlaceNameCharacters = 64
    public static let maxMapItemIDCharacters = 128
    /// People in one plan, the owner included.
    public static let maxAttendees = 16
    public static let maxProviderNameCharacters = 32
    public static let maxPSIPayloadBytes = 32 * 1024
    public static let maxOwnerUtteranceCharacters = 500
}

/// Thrown when a value violates `ProtocolLimits` or a format rule.
public struct ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    public let field: String
    public let reason: String

    public init(_ field: String, _ reason: String) {
        self.field = field
        self.reason = reason
    }

    public var description: String { "\(field): \(reason)" }
}
