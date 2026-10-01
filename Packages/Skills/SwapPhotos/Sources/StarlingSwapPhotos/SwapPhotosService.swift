import Foundation
import StarlingCore

public enum SwapPhotosError: Error, Hashable, Sendable {
    /// The request is for another skill, or an incompatible version.
    case wrongSkill
    /// Swap photos only runs as a link chained after a plan.
    case notChained
    /// The request carries no plan from the conversation it is chained to.
    case noPlan
    /// The plan has not ended yet.
    case planNotOver
    /// Nobody to offer to, or someone who was not in the plan.
    case notInThePlan
    case alreadyStarted(InteractionID)
    case unknownInteraction(InteractionID)
    /// The answer does not fit the step the interaction is at.
    case unexpectedAnswer(InteractionID)
}

/// The Swap photos runtime (ADR 0242). Every send goes through the app's
/// Outbox with the skill's `SkillRef` and the link's `chainedFrom`.
///
/// As the one who opted in: `start` (called when the plan has ended) asks
/// the owner to pick photos; the owner's pick sends one offer, the number of
/// photos, to everyone else in the plan; acceptances are collected.
///
/// As a friend: an offer creates an invitee interaction with a proposal card
/// and nothing else. It never opens the picker or asks for a permission
/// (ARCHITECTURE rule 8). "Share" sends an acceptance; a pass sends nothing.
public actor SwapPhotosService: SkillService {
    public nonisolated let descriptor = SwapPhotos.descriptor
    public nonisolated let events: AsyncStream<SkillEvent>
    private let continuation: AsyncStream<SkillEvent>.Continuation

    private let outbox: Outbox
    private let me: PeerID
    private let planLookup: @Sendable (ConversationID) async -> Plan?
    private let now: @Sendable () -> Date

    private enum Step: Hashable {
        /// Waiting for the owner to pick photos for this question.
        case picking(question: UInt32)
        /// The offer went out; collecting acceptances.
        case offered(Terms, accepted: Set<PeerID>)
        /// A friend's offer, waiting for the owner's answer.
        case invited(from: PeerID, offer: MessageID, terms: Terms, revision: UInt32)
        /// The owner said yes to a friend's offer.
        case accepted
    }

    private struct Session {
        let conversation: ConversationID
        let chainedFrom: ConversationID
        let participants: [PeerID]
        var step: Step
    }

    private var sessions: [InteractionID: Session] = [:]
    private var byConversation: [ConversationID: InteractionID] = [:]

    /// `planLookup` returns the plan made in a conversation on this phone, so
    /// an offer from someone who was not in that plan is dropped.
    public init(outbox: Outbox, me: PeerID, planLookup: @escaping @Sendable (ConversationID) async -> Plan?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.outbox = outbox
        self.me = me
        self.planLookup = planLookup
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
    }

    // MARK: - As the one who opted in

    public func start(_ request: SkillRequest) async throws {
        guard request.intent.skill.id == descriptor.id, request.intent.skill.version.isCompatible(with: descriptor.ref.version) else {
            throw SwapPhotosError.wrongSkill
        }
        guard let chainedFrom = request.chainedFrom else { throw SwapPhotosError.notChained }
        guard let plan = request.inputs.lazy.compactMap({ if case .plan(let plan) = $0 { plan } else { nil } }).first,
              plan.origin == chainedFrom
        else { throw SwapPhotosError.noPlan }
        guard let end = plan.endsAt, now() >= end else { throw SwapPhotosError.planNotOver }
        guard !request.participants.isEmpty, !request.participants.contains(me),
              Set(request.participants).isSubset(of: plan.attendees.peers)
        else { throw SwapPhotosError.notInThePlan }
        guard sessions[request.interaction] == nil, byConversation[request.conversation] == nil else {
            throw SwapPhotosError.alreadyStarted(request.interaction)
        }
        let question = SwapPhotos.pickQuestion(revision: 1)
        sessions[request.interaction] = Session(conversation: request.conversation, chainedFrom: chainedFrom,
                                                participants: request.participants, step: .picking(question: question.revision))
        byConversation[request.conversation] = request.interaction
        emit(request.interaction, .started)
        emit(request.interaction, .ownerNeeded(question))
    }

    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {
        guard let session = sessions[interaction] else { throw SwapPhotosError.unknownInteraction(interaction) }
        switch (session.step, answer) {
        case (.picking(let question), .reply(let revision, .count(let count))) where revision == question && (1...SwapPhotos.maxPhotos).contains(count):
            let terms = try Terms([.photos: .count(count)])
            sessions[interaction]?.step = .offered(terms, accepted: [])
            emit(interaction, .ownerAnswered(question: question))
            for friend in session.participants {
                // Withdrawn while an earlier send waited on a consent sheet.
                guard sessions[interaction] != nil else { return }
                do {
                    try await outbox.send(.propose(try Proposal(round: 0, terms: terms)), to: friend, conversation: session.conversation,
                                          skill: descriptor.ref, chainedFrom: session.chainedFrom)
                } catch {
                    end(interaction, after: error)
                    return
                }
            }

        case (.picking, .pass):
            emit(interaction, .ownerPassed)
            forget(interaction)

        case (.invited(let from, let offer, let terms, let revision), .accept(let accepted)) where accepted == revision:
            sessions[interaction]?.step = .accepted
            do {
                try await outbox.send(.accept(Acceptance(proposal: offer, terms: terms)), to: from, conversation: session.conversation,
                                      skill: descriptor.ref, chainedFrom: session.chainedFrom)
            } catch {
                end(interaction, after: error)
                return
            }
            emit(interaction, .ownerAccepted(revision: revision))

        case (.invited, .pass):
            // Silence: "If you pass, they just won't see it."
            emit(interaction, .ownerPassed)
            forget(interaction)

        default:
            throw SwapPhotosError.unexpectedAnswer(interaction)
        }
    }

    /// A send that did not go out ends the interaction. A declined consent
    /// sheet is the coordinator's to record (it applies the pass), so it
    /// adds nothing here.
    private func end(_ interaction: InteractionID, after error: any Error) {
        switch error {
        case OutboxError.consentDeclined: break
        case OutboxError.denied: emit(interaction, .blockedByPrivacy)
        default: emit(interaction, .failed)
        }
        forget(interaction)
    }

    public func withdraw(_ interaction: InteractionID) async {
        forget(interaction)
    }

    // MARK: - As a friend

    public func handle(_ event: InboxEvent) async {
        guard case .message(let envelope) = event, let skill = envelope.skill, skill.id == descriptor.id,
              skill.version.isCompatible(with: descriptor.ref.version), envelope.recipient == me
        else { return }

        if let id = byConversation[envelope.conversation] {
            receive(envelope, in: id)
            return
        }
        guard case .propose(let offer) = envelope.body,
              let count = Self.photoCount(offer.terms), (1...SwapPhotos.maxPhotos).contains(count),
              let chainedFrom = envelope.chainedFrom
        else { return }
        // Only someone who was in the plan, about a plan this phone was in.
        guard let plan = await planLookup(chainedFrom),
              plan.attendees.peers.contains(envelope.sender), plan.attendees.peers.contains(me)
        else { return }
        // Another message may have opened this conversation while we looked.
        guard byConversation[envelope.conversation] == nil else { return }

        let id = InteractionID()
        let revision: UInt32 = 1
        sessions[id] = Session(conversation: envelope.conversation, chainedFrom: chainedFrom, participants: [envelope.sender],
                               step: .invited(from: envelope.sender, offer: envelope.id, terms: offer.terms, revision: revision))
        byConversation[envelope.conversation] = id
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: chainedFrom))
        emit(id, .proposalReady(SkillProposal(revision: revision, participants: [envelope.sender, me], terms: offer.terms)))
    }

    private func receive(_ envelope: Envelope, in id: InteractionID) {
        guard var session = sessions[id], case .offered(let terms, var accepted) = session.step,
              session.participants.contains(envelope.sender),
              case .accept(let acceptance) = envelope.body, acceptance.terms == terms
        else { return }
        accepted.insert(envelope.sender)
        session.step = .offered(terms, accepted: accepted)
        sessions[id] = session
    }

    /// Who accepted the owner's offer so far, for tests and Developer.
    public func acceptedOffer(_ interaction: InteractionID) -> Set<PeerID> {
        guard case .offered(_, let accepted) = sessions[interaction]?.step else { return [] }
        return accepted
    }

    private static func photoCount(_ terms: Terms) -> Int? {
        guard terms.values.count == 1, case .count(let count) = terms.values[.photos] else { return nil }
        return count
    }

    // MARK: - Restart

    /// A pick the owner had not made yet resumes with the same question.
    /// Anything further along cannot be resumed, because the offer's terms
    /// and message IDs are not stored, so it is reported as failed. A link
    /// still waiting for its plan to end is the scheduler's, not ours.
    public func restore(_ interactions: [Interaction]) async {
        for interaction in interactions where interaction.skill.id == descriptor.id && !interaction.state.isFinal {
            if interaction.state == .drafting { continue }
            if interaction.role == .initiator, interaction.state == .awaitingOwner,
               let question = interaction.pendingQuestion, let chainedFrom = interaction.chain?.parentConversation {
                sessions[interaction.id] = Session(conversation: interaction.conversation, chainedFrom: chainedFrom,
                                                   participants: interaction.participants, step: .picking(question: question.revision))
                byConversation[interaction.conversation] = interaction.id
            } else {
                emit(interaction.id, .failed)
            }
        }
    }

    public func shutdown() async {
        continuation.finish()
    }

    // MARK: - Helpers

    private func emit(_ interaction: InteractionID, _ event: InteractionEvent) {
        continuation.yield(.lifecycle(interaction, event))
    }

    private func forget(_ interaction: InteractionID) {
        if let conversation = sessions.removeValue(forKey: interaction)?.conversation { byConversation[conversation] = nil }
    }
}
