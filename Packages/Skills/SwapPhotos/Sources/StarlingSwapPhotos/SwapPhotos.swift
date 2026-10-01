import Foundation
import StarlingCore

/// Swap photos: after a plan ends, offer the photos you took to the people
/// who were there (brief 2.8, Phase 4). In Phase 1.5 it ships flagged off,
/// built only far enough to prove the after-plan-ends chain hook (ADR 0242):
/// it starts when the plan ends, only if the owner opted in at Confirm; the
/// owner picks photos with the system picker, which needs no photo library
/// permission; and the offer leaves through the Outbox with `chainedFrom`.
/// Moving the photos themselves is Phase 4's.
public enum SwapPhotos {
    /// The skill's descriptor, the same as `StarlingFakes.SampleSkills.swapPhotos`.
    /// It declares `photoLibrary` because the full skill matches photos to the
    /// plan's time, which reads the library; this stub only uses the picker.
    public static let descriptor = try! SkillDescriptor(
        ref: SkillRef(.swapPhotos, SkillVersion(1)),
        wording: SkillWording(
            name: "Swap photos", summary: "Share photos from a plan", startAction: "Swap photos",
            acceptAction: "Share", declineAction: "Not these", declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .matchedExchange,
        topicsUsed: [.photos],
        topicsRequired: [.photos],
        permissions: [.photoLibrary],
        accepts: [.plan],
        produces: [],
        intent: IntentSchema(slots: [IntentSlot(.photos, required: false, hint: "which photos, such as from tonight")],
                             asksForAudience: false, asksForExpiry: false),
        chainTrigger: .afterPlanEnds,
        // Invite only: Ask quietly needs mutual reveal (ADR 0020).
        sendModes: [.invite]
    )

    /// The most photos one offer can name.
    public static let maxPhotos = 24

    /// Whether this build ships Swap photos switched on. False for
    /// `SkillFlags.phase1_5`.
    public static func isEnabled(in flags: SkillFlags) -> Bool { flags.enabled.contains(descriptor.id) }

    /// The question the agent puts to its owner when the plan ends: pick the
    /// photos to offer, up to `maxPhotos`. The picker is shown for this
    /// question only.
    public static func pickQuestion(revision: UInt32) -> SkillQuestion {
        SkillQuestion(revision: revision, issue: .photos, candidates: .count(maxPhotos), asker: nil)
    }

    /// The owner's answer once they picked `count` photos in the picker, or
    /// nil if they picked none or the question is not a Swap photos one.
    public static func answer(picked count: Int, to question: SkillQuestion) -> OwnerAnswer? {
        guard question.issue == .photos, case .count(let limit) = question.candidates, (1...limit).contains(count) else { return nil }
        return .reply(question: question.revision, .count(count))
    }
}
