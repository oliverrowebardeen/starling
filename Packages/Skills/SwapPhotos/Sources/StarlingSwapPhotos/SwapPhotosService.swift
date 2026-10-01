import Foundation
import StarlingCore

public enum SwapPhotosError: Error, Hashable, Sendable {
    /// The request is for another skill, an incompatible version, or a send
    /// mode the skill does not offer.
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
/// As the one who opted in: `start` (called when the plan has ended, after
/// the coordinator applied `.started`) asks the owner to pick photos; the owner's pick sends one offer, the number of
/// photos, to everyone else in the plan; acceptances are collected.
///
/// As a friend: an offer creates an invitee interaction with a proposal card
/// and nothing else. It never opens the picker or asks for a permission
/// (ARCHITECTURE rule 8). A newer offer from the same friend replaces the
/// card. "Share" sends an acceptance; a pass sends nothing.
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
        case invited(from: PeerID, offer: MessageID, proposal: Proposal, revision: UInt32)
        /// The owner said yes to this revision of a friend's offer.
        case accepted(revision: UInt32)
    }

    private struct Session {
        let conversation: ConversationID
        let chainedFrom: ConversationID
        let participants: [PeerID]
        var step: Step
        /// Rises each time the interaction moves to a new step, so a send made
        /// for an earlier step can tell it was superseded (ADR 0011
        /// amendment 14). Collecting acceptances does not change the step.
        var stepID: UInt64 = 0

        mutating func advance(to next: Step) {
            step = next
            stepID += 1
        }
    }

    private var sessions: [InteractionID: Session] = [:]
    private var byConversation: [ConversationID: InteractionID] = [:]
    /// Every send still on its way out, per interaction. A newer offer can
    /// arrive while an acceptance of the older one is waiting, so there can
    /// be more than one.
    private var inFlight: [InteractionID: [UUID: Task<Void, any Error>]] = [:]
    private let ledger: any ConversationLedger
    /// Conversations ended on this launch: a cache in front of the ledger,
    /// filled before the ledger's write, so an envelope that arrives while
    /// the retirement is being recorded is not reopened either.
    private var closed: Set<ConversationID> = []
    /// Retirements the ledger could not record. A ledger that cannot write
    /// cannot read either, so a later offer is still refused (fail closed).
    public private(set) var retireFailures = 0

    /// `ledger` is the app's `ConversationLedger`, the one its Outbox uses
    /// (ADR 0021): a conversation it has retired is never opened again.
    /// `planLookup` returns the plan made in a conversation on this phone, so
    /// an offer from someone who was not in that plan is dropped.
    public init(outbox: Outbox, ledger: any ConversationLedger, me: PeerID, planLookup: @escaping @Sendable (ConversationID) async -> Plan?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.outbox = outbox
        self.ledger = ledger
        self.me = me
        self.planLookup = planLookup
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
    }

    // MARK: - As the one who opted in

    public func start(_ request: SkillRequest) async throws {
        guard request.intent.skill.id == descriptor.id, request.intent.skill.version.isCompatible(with: descriptor.ref.version),
              descriptor.sendModes.contains(request.intent.mode)
        else {
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
        guard sessions[request.interaction] == nil, byConversation[request.conversation] == nil, !closed.contains(request.conversation) else {
            throw SwapPhotosError.alreadyStarted(request.interaction)
        }
        let question = SwapPhotos.pickQuestion(revision: 1)
        sessions[request.interaction] = Session(conversation: request.conversation, chainedFrom: chainedFrom,
                                                participants: request.participants, step: .picking(question: question.revision))
        byConversation[request.conversation] = request.interaction
        // The coordinator applied .started before calling start (ADR 0011).
        emit(request.interaction, .ownerNeeded(question))
    }

    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {
        guard let session = sessions[interaction] else { throw SwapPhotosError.unknownInteraction(interaction) }
        switch (session.step, answer) {
        case (.picking(let question), .reply(let revision, .count(let count))) where revision == question && (1...SwapPhotos.maxPhotos).contains(count):
            let terms = try Terms([.photos: .count(count)])
            let offer = MessageBody.propose(try Proposal(round: 0, terms: terms))
            sessions[interaction]?.advance(to: .offered(terms, accepted: []))
            emit(interaction, .ownerAnswered(question: question))
            _ = await send(session.participants.map { (offer, $0) }, in: interaction, session: session)

        case (.picking, .pass):
            emit(interaction, .ownerPassed)
            await forget(interaction)

        case (.invited(let from, let offer, let proposal, let revision), .accept(let accepted)) where accepted == revision:
            sessions[interaction]?.advance(to: .accepted(revision: revision))
            // Exactly the friend's offer, passed as `accepting` so the policy
            // sees a yes to their own terms (ADR 0019 amendment 10).
            guard await send([(.accept(Acceptance(proposal: offer, terms: proposal.terms)), from)], in: interaction, session: session,
                             accepting: proposal)
            else { return }
            emit(interaction, .ownerAccepted(revision: revision))

        case (.invited, .pass):
            // Silence: "If you pass, they just won't see it."
            emit(interaction, .ownerPassed)
            await forget(interaction)

        default:
            throw SwapPhotosError.unexpectedAnswer(interaction)
        }
    }

    /// Sends `messages` in order, in a task tracked per interaction, so
    /// `withdraw` and `shutdown` cancel a send still waiting on a consent
    /// sheet or on the policy's re-check after it: Outbox checks cancellation
    /// after both, before anything reaches the transport.
    ///
    /// Returns true when every message went out and the interaction is still
    /// at the step the send was made for. A withdrawal reports nothing more.
    /// A failure ends the interaction only if its step is still current: if a
    /// newer offer replaced the card while the send was in flight, the result
    /// belongs to a step that no longer exists and is dropped (ADR 0011
    /// amendment 14).
    private func send(_ messages: [(MessageBody, PeerID)], in interaction: InteractionID, session: Session, accepting: Proposal? = nil) async -> Bool {
        let outbox = outbox
        let skill = descriptor.ref
        let step = sessions[interaction]?.stepID
        let task = Task {
            for (body, peer) in messages {
                try Task.checkCancellation()
                try await outbox.send(body, to: peer, conversation: session.conversation, context: OutboundContext(interaction: interaction, accepting: accepting),
                                      skill: skill, mode: .invite, chainedFrom: session.chainedFrom)
            }
        }
        let key = UUID()
        inFlight[interaction, default: [:]][key] = task
        defer {
            inFlight[interaction]?[key] = nil
            if inFlight[interaction]?.isEmpty == true { inFlight[interaction] = nil }
        }
        do {
            try await task.value
            return sessions[interaction]?.stepID == step
        } catch {
            guard !task.isCancelled, let current = sessions[interaction], current.stepID == step else { return false }
            await end(interaction, after: error)
            return false
        }
    }

    /// A send that did not go out ends the interaction. A declined consent
    /// sheet is the coordinator's to record (it applies the pass), so it
    /// adds nothing here.
    private func end(_ interaction: InteractionID, after error: any Error) async {
        switch error {
        case OutboxError.consentDeclined: break
        case OutboxError.denied: emit(interaction, .blockedByPrivacy)
        default: emit(interaction, .failed)
        }
        await forget(interaction)
    }

    /// Cancels every send still in flight and retires the conversation, so
    /// nothing more leaves for it and nothing reopens it.
    public func withdraw(_ interaction: InteractionID) async {
        await forget(interaction)
    }

    // MARK: - As a friend

    public func handle(_ event: InboxEvent) async {
        // Only the modes this skill offers: anything else is ignored like an
        // unknown request, so a quiet ask never becomes a card (ADR 0020).
        guard case .message(let envelope) = event, let skill = envelope.skill, skill.id == descriptor.id,
              skill.version.isCompatible(with: descriptor.ref.version), envelope.recipient == me,
              let mode = envelope.mode, descriptor.sendModes.contains(mode), !closed.contains(envelope.conversation)
        else { return }

        if let id = byConversation[envelope.conversation] {
            receive(envelope, in: id)
            return
        }
        guard case .propose(let offer) = envelope.body,
              let count = Self.photoCount(offer.terms), (1...SwapPhotos.maxPhotos).contains(count),
              let chainedFrom = envelope.chainedFrom
        else { return }
        // Never a conversation the ledger has retired (ADR 0021). A ledger
        // that cannot answer opens nothing.
        guard (try? await ledger.isRetired(envelope.conversation)) == false else { return }
        // Only someone who was in the plan, about a plan this phone was in.
        guard let plan = await planLookup(chainedFrom),
              plan.attendees.peers.contains(envelope.sender), plan.attendees.peers.contains(me)
        else { return }
        // Another message may have opened, or an ending closed, this
        // conversation while we looked.
        guard byConversation[envelope.conversation] == nil, !closed.contains(envelope.conversation) else { return }

        let id = InteractionID()
        let revision: UInt32 = 1
        sessions[id] = Session(conversation: envelope.conversation, chainedFrom: chainedFrom, participants: [envelope.sender],
                               step: .invited(from: envelope.sender, offer: envelope.id, proposal: offer, revision: revision))
        byConversation[envelope.conversation] = id
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: chainedFrom))
        emit(id, .proposalReady(SkillProposal(revision: revision, participants: [envelope.sender, me], terms: offer.terms)))
    }

    private func receive(_ envelope: Envelope, in id: InteractionID) {
        guard var session = sessions[id], session.participants.contains(envelope.sender) else { return }
        switch (session.step, envelope.body) {
        case (.offered(let terms, var accepted), .accept(let acceptance)) where acceptance.terms == terms:
            accepted.insert(envelope.sender)
            session.step = .offered(terms, accepted: accepted)
            sessions[id] = session

        // The friend sent a newer offer: it replaces the one on the card,
        // answered or not, as a newer proposal does for any skill (ADR 0011).
        case (.invited(_, _, _, let revision), .propose(let offer)), (.accepted(let revision), .propose(let offer)):
            guard revision < UInt32(ProtocolLimits.maxNegotiationRounds), envelope.chainedFrom == session.chainedFrom,
                  let count = Self.photoCount(offer.terms), (1...SwapPhotos.maxPhotos).contains(count)
            else { return }
            let next = revision + 1
            session.advance(to: .invited(from: envelope.sender, offer: envelope.id, proposal: offer, revision: next))
            sessions[id] = session
            emit(id, .proposalReady(SkillProposal(revision: next, participants: [envelope.sender, me], terms: offer.terms)))

        default:
            return
        }
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
    /// still waiting for its plan to end is the scheduler's, not ours. The
    /// coordinator also passes interactions that ended in the last day; they
    /// are retired again, in case the app quit before it recorded that.
    public func restore(_ interactions: [Interaction]) async {
        for interaction in interactions where interaction.skill.id == descriptor.id {
            if interaction.state.isFinal {
                await retire(interaction.conversation)
                continue
            }
            if interaction.state == .drafting { continue }
            if interaction.role == .initiator, interaction.state == .awaitingOwner,
               let question = interaction.pendingQuestion, let chainedFrom = interaction.chain?.parentConversation {
                sessions[interaction.id] = Session(conversation: interaction.conversation, chainedFrom: chainedFrom,
                                                   participants: interaction.participants, step: .picking(question: question.revision))
                byConversation[interaction.conversation] = interaction.id
            } else {
                emit(interaction.id, .failed)
                await retire(interaction.conversation)
            }
        }
    }

    public func shutdown() async {
        for tasks in inFlight.values { for task in tasks.values { task.cancel() } }
        inFlight = [:]
        continuation.finish()
    }

    // MARK: - Helpers

    private func emit(_ interaction: InteractionID, _ event: InteractionEvent) {
        continuation.yield(.lifecycle(interaction, event))
    }

    /// Ends the session here: cancels every send still in flight for it and
    /// retires its conversation, so a friend's retried offer after a pass
    /// never shows the card again, after a restart too.
    private func forget(_ interaction: InteractionID) async {
        if let tasks = inFlight.removeValue(forKey: interaction) { for task in tasks.values { task.cancel() } }
        guard let conversation = sessions.removeValue(forKey: interaction)?.conversation else { return }
        byConversation[conversation] = nil
        await retire(conversation)
    }

    /// Records the ending in the ledger through Outbox, which also cancels any
    /// send of the conversation still waiting in its queue or the
    /// transport's (ADR 0021 decision 10).
    private func retire(_ conversation: ConversationID) async {
        closed.insert(conversation)
        do { try await outbox.retire(conversation) } catch { retireFailures += 1 }
    }
}
