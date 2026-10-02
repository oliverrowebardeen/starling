import Foundation
import StarlingCore

/// The Down for... skill: "see who's up for something", by mutual reveal.
/// Friends' agents find shared free time with PSI first; details travel only
/// after overlap; and nobody is told anything unless a plan forms
/// (brief 2.6, ADR 0120, ADR 0210).
public enum DownFor {
    public static let ref = SkillRef(.downFor, SkillVersion(1, 0))

    /// Plan words (ADR 0017). The name always travels with an activity on
    /// screen: "Down for boba", never "Down?".
    public static let wording = SkillWording(
        name: "Down for…",
        summary: "See who's up for something",
        startAction: "See who's up for it",
        acceptAction: "I'm in",
        declineAction: "Not tonight",
        declineNote: "If you pass, they just won't see it."
    )

    /// The mutual-reveal line for New and the status card.
    public static let revealNote = "If nobody's up for it, nobody sees you asked."

    // Force-try is safe: the values are constant and covered by a test.
    public static let descriptor = try! SkillDescriptor(
        ref: ref,
        wording: wording,
        buildingBlock: .mutualReveal,
        // Place and budget are read from the owner's words as chips but
        // never sent: Pick a place agrees on venues (ADR 0012), and budget
        // stays on the phone (ADR 0019 makes Never its default). The roster
        // travels under people only in an invitation to a group.
        topicsUsed: [.time, .activity, .place, .budget, .people],
        topicsRequired: [.time, .activity],
        accepts: [.timeSlot],
        produces: [.plan, .attendees],
        intent: try! IntentSchema(slots: [
            IntentSlot(.activity, required: true, hint: "what they want to do, such as boba or a walk"),
            IntentSlot(.time, required: false, hint: "when, such as tonight after 7"),
            IntentSlot(.place, required: false, hint: "where or how far, such as nearby"),
            IntentSlot(.budget, required: false, hint: "the most they want to spend"),
        ]),
        // Ask quietly by default: mutual reveal. Invite shows the request to
        // friends directly (ADR 0020).
        sendModes: [.askQuietly, .invite]
    )
}
