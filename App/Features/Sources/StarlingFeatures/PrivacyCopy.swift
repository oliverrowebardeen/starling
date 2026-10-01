import Foundation
import StarlingCore

/// The words You shows for privacy topics (ADR 0019 decision 8; lane A
/// owns the final copy). Each control explains the choice it is set to.
public enum PrivacyCopy {
    /// One line under the control for the selected choice.
    public static func explanation(_ choice: SharingChoice) -> String {
        switch choice {
        case .share: "Sent without asking to friends whose agent runs on their phone. Anyone else still needs your OK."
        case .askMe: "You see and approve exactly what's sent, every time. Your agent can still say whether a friend's option works."
        case .never: "Stays on this phone. Your agent uses it to say yes or no to a friend's options, so friends can learn whether an option works for you."
        }
    }

    /// The line in place of time and activity's rows (ADR 0017 decision 4).
    public static let overlapNote = "Time and activity are always shared as the overlap. Nothing can line up without them."

    /// Every topic with a control, in the order You shows them.
    public static let topics: [PrivacyTopic] = PrivacyTopic.allCases.filter(\.allowsNever)

    /// Whether any skill sends values of this topic. In Phase 1.5 no skill
    /// sends calendar details: Find a time sends free and busy times only
    /// (ADR 0019 decision 9).
    public static func isSentBySomeSkill(_ topic: PrivacyTopic) -> Bool {
        topic != .calendarDetails
    }

    /// Shown under a topic no skill sends yet, while it is not Never.
    public static let notUsedYet = "Share and Ask me aren't used by any skill yet. Find a time reads your calendar's details on this phone only."
}
