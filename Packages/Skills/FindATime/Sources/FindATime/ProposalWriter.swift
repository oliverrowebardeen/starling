import Foundation
import StarlingCore

/// Writes the sentence on a Find a time proposal card (ADR 0016): the
/// model's sentence when it is available, the template otherwise.
///
/// The prompt gets `ProposalFacts` only: the owner's own nicknames for the
/// friends in the plan, the activity keyword, and the agreed time. Nothing
/// from a calendar can reach it, because the proposal carries none: a
/// `SkillProposal` holds typed terms and a `Plan`, built from candidate
/// times, never from events.
public struct FindATimeProposalWriter: Sendable {
    private let model: (any SkillModel)?
    private let localPeer: PeerID
    private let nickname: @Sendable (PeerID) async -> String?
    private let timeZone: TimeZone

    /// - Parameter nickname: The owner's name for a paired friend, from the
    ///   phone's friend list. Never text a peer sent.
    public init(model: (any SkillModel)?, localPeer: PeerID, timeZone: TimeZone, nickname: @escaping @Sendable (PeerID) async -> String?) {
        self.model = model
        self.localPeer = localPeer
        self.timeZone = timeZone
        self.nickname = nickname
    }

    public func facts(for proposal: SkillProposal) async -> ProposalFacts {
        var names: [String] = []
        for peer in proposal.participants where peer != localPeer {
            names.append(await nickname(peer) ?? "a friend")
        }
        let time: TimeSlot? = proposal.plan?.time ?? {
            if case .slots(let slots)? = proposal.terms[.time] { return slots.first }
            return nil
        }()
        let activity: Keyword? = proposal.plan?.activity ?? {
            if case .keywords(let keywords)? = proposal.terms[.activity] { return keywords.first }
            return nil
        }()
        return ProposalFacts(skill: FindATimeSkill.ref, friendNames: names, activity: activity, time: time, place: nil, timeZone: timeZone)
    }

    /// The card's sentence. A model error or an empty answer falls back to
    /// the template, so Find a time works without Apple Intelligence.
    public func sentence(for proposal: SkillProposal) async -> String {
        let facts = await facts(for: proposal)
        if let model, let result = try? await model.proposalText(facts) {
            let text = result.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return FindATimeTemplate.sentence(facts)
    }
}
