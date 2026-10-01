import Foundation
import StarlingCore

/// The Find a time skill's data half (ADR 0010): what it is, what it
/// touches, and the words the shared screens show for it.
public enum FindATimeSkill {
    public static let ref = SkillRef(.findATime, SkillVersion(1, 0))

    /// Starts from `StarlingFakes.SampleSkills.findATime` and adds the
    /// people topic: a group plan carries its roster under `IssueKey.people`
    /// (ADR 0012), and ADR 0014 requires every topic a skill sends to be in
    /// `topicsUsed`. A two-person plan sends no roster.
    public static let descriptor = try! SkillDescriptor(
        ref: ref,
        wording: SkillWording(
            name: "Find a time", summary: "Agree on when", startAction: "Find a time",
            acceptAction: "That works", declineAction: "Not then", declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .privateQuery,
        topicsUsed: [.time, .activity, .people],
        topicsRequired: [.time],
        permissions: [.calendarFullAccess],
        produces: [.timeSlot, .plan],
        intent: IntentSchema(slots: [
            IntentSlot(.time, required: true, hint: "the range to look in, such as next week"),
            IntentSlot(.activity, required: false, hint: "what it is for, such as stats"),
        ])
    )
}

/// Fixed words for Find a time's screens, in plan words (ADR 0017). The app
/// owns the screens; the skill owns what they say about it.
public enum FindATimeCopy {
    /// Starling's sheet before the system calendar alert (ADR 0013,
    /// decision 3): one button, "Continue", which leads to the alert.
    public enum PermissionSheet {
        public static let title = "Find a time works best with your calendar"
        public static let body = "Your agent checks when you're busy, right here on your iPhone, so friends' agents don't have to ask you."
        public static let readsLabel = "Your agent reads"
        public static let readsValue = "When you're busy or free"
        public static let staysLabel = "Never leaves your phone"
        public static let staysValue = "Event names, places, people"
        /// "Priya sees" or "Your friends see".
        public static func seesLabel(friend: String?) -> String { friend.map { "\($0) sees" } ?? "Your friends see" }
        /// What the friend sees when you start Find a time: the times you
        /// offer, never why the others are taken (ADR 0221).
        public static let seesValueWhenAsking = "Only a few times you're free"
        /// What the friend sees when you answer their request.
        public static let seesValueWhenAnswering = "Only times you're both free"
        public static let continueButton = "Continue"
        public static let footnote = "Change this anytime in You › Skills."
    }

    /// Shown right after the system's Don't Allow.
    public static let deniedFallback = "No problem, your agent will ask you instead."
    /// You › Skills switch labels.
    public static let useMyCalendar = "Use my calendar"
    public static let justAskMe = "Just ask me"

    /// The owner's own question when the agent cannot read a calendar.
    public static let askOwnTimes = "When works for you?"
    /// An invitee's question: "Priya's agent asked when you're free".
    public static func askedBy(_ friend: String) -> String { "\(friend)'s agent asked when you're free" }
    public static let answerNote = "Shares only the times you're both free"
}

/// The template sentence for a proposal card when the model is unavailable
/// (ADR 0016): "You and Priya are free Thursday, October 8 at 4:00 PM for stats."
public enum FindATimeTemplate {
    public static func sentence(_ facts: ProposalFacts, locale: Locale = Locale(identifier: "en_US")) -> String {
        let people = (["You"] + facts.friendNames).joinedAsList()
        var sentence = "\(people) are free"
        if let time = facts.time {
            let format = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, timeZone: facts.timeZone)
                .year(.omitted)
            sentence += " \(time.start.formatted(format))"
        }
        if let activity = facts.activity { sentence += " for \(activity.value)" }
        return sentence + "."
    }
}

extension Array where Element == String {
    /// "You", "You and Priya", "You, Maya and Jake".
    func joinedAsList() -> String {
        switch count {
        case 0: ""
        case 1: self[0]
        default: dropLast().joined(separator: ", ") + " and " + last!
        }
    }
}
