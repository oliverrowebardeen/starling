import StarlingCore

extension Interaction {
    /// The conversation that names this interaction's plan to everyone in
    /// it: the conversation the plan was agreed in (`Plan.origin`), or, for
    /// an interaction without a plan, its own. Chains carry it as
    /// `chainedFrom`. On every phone that was in the agreement it is the
    /// root interaction's own conversation; a friend added to the plan later
    /// (ADR 0022) holds the plan in another interaction, so only the origin
    /// names the same plan on every phone.
    public var planConversation: ConversationID { plan?.origin ?? conversation }
}
