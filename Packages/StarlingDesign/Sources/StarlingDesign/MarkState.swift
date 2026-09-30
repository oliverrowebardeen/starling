/// What the status mark is showing. Shape A is you; shape B is the other person.
public enum MarkState: String, CaseIterable, Hashable, Sendable {
    /// Two people, apart.
    case idle
    /// Your intent is out: your shape pulses and both drift.
    case searching
    /// The agents are talking: the shapes slide in and the gap opens.
    case negotiating
    /// Both said yes: the gap fills with light, then fades, and the mark rests as the logo.
    case match
    /// No overlap: the shapes drift apart and the other one fades. No sound, no message.
    case noMatch

    /// Spoken by VoiceOver. Deliberately neutral for `noMatch`.
    public var accessibilityLabel: String {
        switch self {
        case .idle: "Starling"
        case .searching: "Looking for a match"
        case .negotiating: "Agents are talking"
        case .match: "Matched"
        case .noMatch: "Starling"
        }
    }
}
