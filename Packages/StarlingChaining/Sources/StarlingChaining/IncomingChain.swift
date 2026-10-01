import Foundation
import StarlingCore

// A peer's `chainedFrom` (ADR 0012 decision 6, ARCHITECTURE rule 8). An
// incoming envelope that names an earlier conversation creates an invitee
// interaction like any other request. The name is a hint for grouping that
// interaction on the plan's timeline, and nothing more: it is never a
// `ChainLink` (those record the owner's own opt-in), it never starts a skill
// or the after-plan-ends schedule, it never asks for a permission, and it
// never skips Consent. This file decides only whether the hint may group.

public enum IncomingChain {
    /// The conversation `chainedFrom` names, when it is a plan on this phone
    /// and `sender` is one of the plan's attendees. Otherwise nil, and the invitee interaction
    /// stands on its own. A peer cannot attach its request to a plan it was
    /// never in, or to a conversation that never became a plan.
    public static func timelineParent(chainedFrom: ConversationID?, sender: PeerID, interactions: [Interaction]) -> ConversationID? {
        guard let chainedFrom,
              let parent = interactions.first(where: { $0.conversation == chainedFrom }),
              parent.state == .planned || parent.state == .done,
              let plan = parent.plan
        else { return nil }
        // The plan's final attendees only (ADR 0240 decision 7): someone who
        // was asked but is not in the plan is not a member of it.
        return plan.attendees.peers.contains(sender) ? chainedFrom : nil
    }
}
