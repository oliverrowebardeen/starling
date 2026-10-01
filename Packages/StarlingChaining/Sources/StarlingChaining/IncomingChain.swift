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
    /// that `sender` is part of. Otherwise nil, and the invitee interaction
    /// stands on its own. A peer cannot attach its request to a plan it was
    /// never in, or to a conversation that never became a plan.
    public static func timelineParent(chainedFrom: ConversationID?, sender: PeerID, interactions: [Interaction]) -> ConversationID? {
        guard let chainedFrom,
              let parent = interactions.first(where: { $0.conversation == chainedFrom }),
              parent.state == .planned || parent.state == .done
        else { return nil }
        let members = Set(parent.participants).union(parent.plan?.attendees.peers ?? [])
        return members.contains(sender) ? chainedFrom : nil
    }
}
