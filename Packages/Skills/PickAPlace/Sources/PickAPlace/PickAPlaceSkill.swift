import Foundation
import StarlingCore

/// The Pick a place skill: friends' agents agree on a venue from each
/// person's private limits (budget, diet, places to avoid) without anyone
/// sending those limits (brief 2.6.3, private aggregation; ADR 0230).
public enum PickAPlaceSkill {
    public static let ref = SkillRef(.pickAPlace, SkillVersion(1, 0))

    /// Starts from `SampleSkills.pickAPlace`, with two changes (ADR 0230):
    /// - People is used and required, because the agreed roster travels as
    ///   `IssueValue.peers` so every phone builds the same plan (ADR 0012).
    /// - Time and activity are used, because a chained pick carries the
    ///   plan's time and activity in the proposal, so a friend who joined
    ///   through Find a time builds the same plan.
    /// Budget and diet stay in `topicsUsed` only because the intent reads
    /// them; their values never leave the phone.
    public static let descriptor = try! SkillDescriptor(
        ref: ref,
        wording: SkillWording(
            name: "Pick a place",
            summary: "Agree on where",
            startAction: "Find a place",
            acceptAction: "Sounds good",
            declineAction: "Not this one",
            declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .privateAggregation,
        topicsUsed: [.place, .budget, .diet, .people, .time, .activity],
        topicsRequired: [.place, .people],
        permissions: [.locationWhenInUse],
        accepts: [.plan, .timeSlot],
        produces: [.placeChoice],
        intent: IntentSchema(slots: [
            IntentSlot(.place, required: false, hint: "the kind of place or area, such as dinner near Franklin"),
            IntentSlot(.budget, required: false, hint: "the most they want to spend each"),
            IntentSlot(.diet, required: false, hint: "what they need or can't eat, such as vegetarian or no pork"),
        ])
    )
}
