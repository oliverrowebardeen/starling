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
    /// - It also produces `Attendees`: the people who said yes, which can be
    ///   fewer than the proposal named.
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
        produces: [.placeChoice, .attendees],
        intent: IntentSchema(slots: [
            IntentSlot(.place, required: false, hint: "the kind of place or area, such as dinner near Franklin"),
            IntentSlot(.budget, required: false, hint: "the most they want to spend each"),
            IntentSlot(.diet, required: false, hint: "what they need or can't eat, such as vegetarian or no pork"),
        ])
    )

    /// The candidates `start` would ask friends about: those that fit the
    /// owner's own limits, best first. Compose checks this is not empty
    /// before the owner sends, because a `start` that throws ends the
    /// interaction as failed (ADR 0011, amendment 13).
    public static func askable(_ candidates: [PlaceCandidate], limits: ConstraintSet) -> [PlaceChoice] {
        var seen: Set<PlaceChoice> = []
        let unique = candidates.filter { seen.insert($0.choice).inserted }.prefix(ProtocolLimits.maxPlacesPerValue)
        return PlaceJudge.acceptable(Array(unique), limits: limits)
    }

    /// `NSLocationWhenInUseUsageDescription`. Lane A puts it in the app's
    /// Info.plist (ADR 0013, decision 6).
    public static let locationPurpose =
        "Starling uses your location only while it finds places near you. Your location stays on your iPhone; friends see only the places you suggest."

    /// Starling's own sheet before the system alert: one Continue button
    /// (ADR 0013). Shown the first time the owner asks for nearby places.
    public static let locationSheet = PermissionSheet(
        title: "Find places near you",
        reads: "Where you are, only while it looks for places",
        staysOnPhone: "Your location",
        friendsSee: "Only the places you suggest",
        continueAction: "Continue",
        deniedNote: "No problem. Type a place or an area instead."
    )
}

/// The words on Starling's pre-permission sheet, for the shared component.
public struct PermissionSheet: Hashable, Sendable {
    public let title: String
    /// "Your agent reads"
    public let reads: String
    /// "Never leaves your phone"
    public let staysOnPhone: String
    /// "Your friends see"
    public let friendsSee: String
    public let continueAction: String
    /// Shown right after the owner chooses Don't Allow.
    public let deniedNote: String
}
