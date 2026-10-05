import CryptoKit
import Foundation
import StarlingCore

/// The plan a conversation names on this phone: the interaction that holds
/// it, and the plan as it stands.
public struct PlanRef: Hashable, Sendable {
    public let interaction: InteractionID
    public let plan: Plan

    public init(interaction: InteractionID, plan: Plan) {
        self.interaction = interaction
        self.plan = plan
    }
}

public enum ChangePlanError: Error, Hashable, Sendable {
    /// Another skill, an incompatible version, or a mode this skill does not offer.
    case wrongSkill
    /// Change the plan only runs chained to a plan.
    case notChained
    /// This phone has no standing plan for the request's conversation.
    case noPlan
    /// The plan changed since the request was made.
    case stale
    /// Another change to this plan is in progress on this phone, from this
    /// skill or another (ADR 0022 decision 6, ADR 0023): a suggestion cannot
    /// start, and a yes cannot be given, until it ends.
    case planBusy
    /// The request's people are not the plan's.
    case notInThePlan
    case alreadyStarted(InteractionID)
    case unknownInteraction(InteractionID)
    case unexpectedAnswer(InteractionID)
    /// The journal could not record what a restart would need, so the
    /// action did not happen (issue #117).
    case journalUnavailable
}

/// The Change the plan runtime (ADR 0022, ADR 0243). Every send goes
/// through the app's Outbox with the skill, mode invite, the plan's origin
/// as `chainedFrom`, and the interaction in `OutboundContext`.
///
/// The suggester asks everyone else in the plan with one offer each, which
/// names the plan revision it changes (in `Proposal.round`). Each says yes
/// to the suggester only; a no is silence. When all have said yes (and an
/// added friend has accepted their invite), the suggester confirms to each,
/// and every phone applies the change to its plan, revision one higher.
/// Otherwise, when the window closes, nothing changes: the suggester's card
/// ends as "The plan stays as it was", the others' cards just close.
///
/// Leaving sends each other person a notice that discloses nothing; their
/// plans shrink, and a plan left with one person ends.
///
/// Every state a reply is matched against is registered before the send
/// that could prompt it (issue #105); an offer's message ID, known only once
/// Outbox returns, is matched by holding any reply that arrives first.
/// Every ending retires the conversation before anything is announced.
public actor ChangePlanService: SkillService {
    public nonisolated let descriptor = ChangePlan.descriptor
    public nonisolated let events: AsyncStream<SkillEvent>
    private let continuation: AsyncStream<SkillEvent>.Continuation

    private let outbox: Outbox
    private let ledger: any ConversationLedger
    private let me: PeerID
    private let planLookup: @Sendable (ConversationID) async -> PlanRef?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Date) async throws -> Void

    private enum Role: Hashable { case suggester, voter, joiner }

    private enum Step: Hashable {
        /// Suggester: waiting for everyone's yes.
        case asking
        /// Suggester: everyone said yes; waiting for the added friend.
        case inviting
        /// Voter or joiner: the card is up.
        case deciding(offer: MessageID, proposal: Proposal)
        /// Voter or joiner: the yes is on its way out.
        case accepting(offer: MessageID)
        /// Voter or joiner: said yes; waiting for the suggester's confirmation.
        case accepted(offer: MessageID)
        /// Suggester: everyone agreed; the commit is being made durable. A
        /// withdrawal or the window now aborts it (review of PR #111).
        case committing
        /// Withdrawn or settled: nothing more counts while its notices go out.
        case ending
    }

    private struct Session {
        let role: Role
        let conversation: ConversationID
        /// The plan's origin, which every envelope carries as `chainedFrom`.
        let planConversation: ConversationID
        /// Where the plan lives on this phone; nil for a friend being added,
        /// whose plan this interaction will hold.
        let planInteraction: InteractionID?
        let basisRevision: UInt32
        /// The plan as it stood when the suggestion was made or shown; nil
        /// for a friend being added, who had none.
        let basis: Plan?
        let proposed: Plan
        /// Voter or joiner: who suggested it.
        let suggester: PeerID?
        /// Suggester: everyone else in the plan, and a friend to add.
        let voters: [PeerID]
        let friend: PeerID?
        /// What the voters were asked, and what the friend is shown.
        let terms: Terms
        let inviteTerms: Terms?
        var yes: Set<PeerID> = []
        /// What was sent to whom, recorded as each send returns.
        var offers: [PeerID: MessageID] = [:]
        /// Acceptances that arrived before their offer's ID was recorded.
        var early: [PeerID: MessageID] = [:]
        var step: Step
        var stepID: UInt64 = 0
        /// A confirmation that arrived while the yes was still going out.
        var heldConfirmation = false
        /// After saying yes: how long the confirmation may still come.
        var holdUntil: Date?
        /// A card's decision window.
        var deadline: Date?

        mutating func advance(to next: Step) {
            step = next
            stepID += 1
        }

        /// Everyone the suggester asked, in plan order, then the friend.
        var asked: [PeerID] { voters + (friend.map { [$0] } ?? []) }

        /// A withdrawal notice for each offer already sent, in plan order.
        var withdrawals: [(MessageBody, PeerID)] {
            asked.compactMap { peer in offers[peer].map { (MessageBody.reject(Rejection(proposal: $0, reason: .declinedByOwner)), peer) } }
        }
    }

    private var sessions: [InteractionID: Session] = [:]
    private var byConversation: [ConversationID: InteractionID] = [:]
    /// The open suggestion for each plan (by the plan's origin).
    private var openByPlan: [ConversationID: InteractionID] = [:]
    /// Suggestions that arrived while another was open for the same plan.
    private var queued: [ConversationID: [Envelope]] = [:]
    private var inFlight: [InteractionID: [UUID: Task<Void, any Error>]] = [:]
    private var timers: [InteractionID: Task<Void, Never>] = [:]
    /// Conversations ended on this launch: a cache in front of the ledger.
    private var closed: Set<ConversationID> = []
    private var unretired: Set<ConversationID> = []
    public private(set) var retireFailures = 0

    // Reliable confirmations and leave notices (ADR 0243): what is owed
    // acknowledgments, and what this phone applied, mirrored in the journal.
    private let journal: any ChangePlanJournal
    private let resend: ResendSchedule
    private var confirming: [InteractionID: ConfirmationDelivery] = [:]
    private var confirmingByConversation: [ConversationID: InteractionID] = [:]
    private var applied: [ConversationID: AppliedConfirmation] = [:]
    private var leaving: [InteractionID: LeaveDelivery] = [:]
    /// Departures this phone applied, by their ID.
    private var departed: [MessageID: Departure] = [:]
    /// Resend loops and end-of-window cleanups, by record key.
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Journal writes that failed. Each one stops or holds the action it
    /// would have let a restart recover (issue #117).
    public private(set) var journalFailures = 0
    /// One change per plan at a time, shared with every skill that changes
    /// plans (ADR 0023).
    private let holds: any PlanChangeHolding
    /// Cards whose yes is journaled, so ending them clears the record.
    private var journaledYes: Set<InteractionID> = []
    /// Friends' cards from their `hello`, passed on every send so the policy
    /// knows where their model runs (as Pick a place does). Without one, the
    /// policy asks for consent even for a send that carries no values.
    private var cards: [PeerID: AgentCard] = [:]

    /// At most this many suggestions wait behind an open one, per plan.
    static let maxQueued = 4

    /// - Parameters:
    ///   - ledger: the app's `ConversationLedger`, the one its Outbox uses.
    ///   - planLookup: the standing plan a conversation names on this phone
    ///     (by `Plan.origin`), with the interaction that holds it.
    ///   - journal: durable storage for confirmations and leave notices still
    ///     owed acknowledgments, and for what this phone applied.
    ///   - resend: how unacknowledged ones are resent.
    ///   - sleep: waits until a date; a suggestion's window closes then.
    public init(outbox: Outbox, ledger: any ConversationLedger, journal: any ChangePlanJournal, holds: any PlanChangeHolding, me: PeerID,
                planLookup: @escaping @Sendable (ConversationID) async -> PlanRef?, resend: ResendSchedule = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Date) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow))) }) {
        self.outbox = outbox
        self.ledger = ledger
        self.journal = journal
        self.holds = holds
        self.resend = resend
        self.me = me
        self.planLookup = planLookup
        self.now = now
        self.sleep = sleep
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
    }

    // MARK: - Suggesting and leaving

    public func start(_ request: SkillRequest) async throws {
        guard request.intent.skill.id == descriptor.id, request.intent.skill.version.isCompatible(with: descriptor.ref.version),
              descriptor.sendModes.contains(request.intent.mode)
        else { throw ChangePlanError.wrongSkill }
        guard let planConversation = request.chainedFrom else { throw ChangePlanError.notChained }
        guard sessions[request.interaction] == nil, byConversation[request.conversation] == nil, !closed.contains(request.conversation) else {
            throw ChangePlanError.alreadyStarted(request.interaction)
        }
        let (basis, change) = try PlanChange.decode(request)
        guard let current = await planLookup(planConversation), current.plan.origin == planConversation else { throw ChangePlanError.noPlan }
        guard current.plan.revision == basis.revision, current.plan.attendees == basis.attendees else { throw ChangePlanError.stale }
        let others = basis.attendees.peers.filter { $0 != me }
        guard basis.attendees.peers.contains(me), Set(request.participants) == Set(others) else { throw ChangePlanError.notInThePlan }

        if change == .leave {
            try await leave(request, plan: current, others: others)
            return
        }
        guard openByPlan[planConversation] == nil else { throw ChangePlanError.planBusy }
        guard basis.revision < UInt32(ProtocolLimits.maxNegotiationRounds - 1) else { throw ChangePlanError.stale }
        // Held before the first offer (ADR 0023): while another change to
        // this plan is in progress here, this one does not start.
        guard await holds.hold(planConversation, for: request.conversation) else { throw ChangePlanError.planBusy }
        // Nothing else may have started while the hold was asked for.
        guard openByPlan[planConversation] == nil, sessions[request.interaction] == nil, byConversation[request.conversation] == nil else {
            await holds.release(planConversation, for: request.conversation)
            throw ChangePlanError.planBusy
        }
        let proposed = try change.applied(to: basis)
        let terms = try change.terms(for: basis)
        var friend: PeerID?
        if case .change(_, _, let adding) = change { friend = adding }
        let deadline = request.intent.expiresAt.date

        // Everything a reply is matched against, before any send (#105).
        sessions[request.interaction] = Session(
            role: .suggester, conversation: request.conversation, planConversation: planConversation, planInteraction: current.interaction,
            basisRevision: basis.revision, basis: basis, proposed: proposed, suggester: nil, voters: others, friend: friend, terms: terms,
            inviteTerms: friend == nil ? nil : try PlanChange.inviteTerms(for: proposed), step: .asking
        )
        byConversation[request.conversation] = request.interaction
        openByPlan[planConversation] = request.interaction
        schedule(request.interaction, at: deadline)

        // The suggestion is the owner's own yes.
        emit(request.interaction, .proposalReady(SkillProposal(revision: 1, participants: proposed.attendees.peers, terms: terms, plan: proposed)))
        emit(request.interaction, .ownerAccepted(revision: 1))

        // The roster asked travels with the offer (finding G), so a phone
        // applies only a change put to everyone else in its plan.
        let offer = try Proposal(round: UInt16(basis.revision), terms: terms,
                                 inReplyTo: Self.rosterDigest(origin: planConversation, revision: basis.revision, suggester: me, asked: others),
                                 expiresAt: request.intent.expiresAt)
        _ = await send(others.map { (MessageBody.propose(offer), $0) }, in: request.interaction, recordOffers: true)
    }

    /// Leaving: tell everyone else, then end this phone's plan. Nothing is
    /// disclosed but that the owner left. The notices are resent until each
    /// person acknowledges them, so every other phone's plan shrinks.
    private func leave(_ request: SkillRequest, plan: PlanRef, others: [PeerID]) async throws {
        // One ID for this departure, registered before any notice is sent,
        // and durable first: a leave a restart could not finish does not start.
        let delivery = LeaveDelivery(interaction: request.interaction, planConversation: plan.plan.origin, revision: plan.plan.revision,
                                     departure: MessageID(), order: others, pending: Set(others), until: resend.end(for: plan.plan, now: now()))
        guard await store(.leaving(delivery)) else { throw ChangePlanError.journalUnavailable }
        leaving[request.interaction] = delivery
        sessions[request.interaction] = Session(
            role: .suggester, conversation: request.conversation, planConversation: plan.plan.origin, planInteraction: plan.interaction,
            basisRevision: plan.plan.revision, basis: plan.plan, proposed: plan.plan, suggester: nil, voters: others, friend: nil, terms: Terms.empty,
            inviteTerms: nil, step: .asking
        )
        byConversation[request.conversation] = request.interaction
        await sendLeaveNotices(request.interaction)
        await settle(planConversation: plan.plan.origin)
        await retire(plan.plan.origin)
        await finish(request.interaction, with: [.withdrawn], then: [.lifecycle(plan.interaction, .withdrawn)])
        startResending(request.interaction.rawValue)
    }

    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {
        guard let session = sessions[interaction] else { throw ChangePlanError.unknownInteraction(interaction) }
        switch (session.step, answer) {
        case (.deciding(let offer, let proposal), .accept(let revision)) where revision == 1:
            guard let suggester = session.suggester else { throw ChangePlanError.unexpectedAnswer(interaction) }
            // Held before the yes (ADR 0023): no yes while another change to
            // this plan is in progress here. The card stays open, and the app
            // says another change is in progress.
            guard await holds.hold(session.planConversation, for: session.conversation) else { throw ChangePlanError.planBusy }
            guard sessions[interaction]?.step == .deciding(offer: offer, proposal: proposal) else {
                await holds.release(session.planConversation, for: session.conversation)
                throw ChangePlanError.unexpectedAnswer(interaction)
            }
            // Registered before the send: the confirmation names this offer.
            // A fast one that arrives while the yes is still going out is
            // held until the yes is recorded (review of PR #111, finding E).
            sessions[interaction]?.advance(to: .accepting(offer: offer))
            // Durable before the yes leaves (finding 1, issue #117): a
            // confirmation that comes late, or after a restart, still finds
            // it. If it cannot be, no yes is sent.
            let record = AcceptedOffer(
                interaction: interaction, conversation: session.conversation, planConversation: session.planConversation,
                joining: session.role == .joiner, suggester: suggester, offer: offer, basis: session.basis, proposed: session.proposed,
                planInteraction: session.planInteraction, until: resend.end(for: session.proposed, now: now())
            )
            guard await store(.accepted(record)) else {
                if sessions[interaction]?.step == .accepting(offer: offer) {
                    sessions[interaction]?.advance(to: .deciding(offer: offer, proposal: proposal))
                }
                await holds.release(session.planConversation, for: session.conversation)
                throw ChangePlanError.journalUnavailable
            }
            // Withdrawn while it was recorded: the record goes with the card.
            guard sessions[interaction]?.step == .accepting(offer: offer) else {
                await forget(interaction.rawValue)
                return
            }
            journaledYes.insert(interaction)
            sessions[interaction]?.holdUntil = record.until
            guard await send([(.accept(Acceptance(proposal: offer, terms: proposal.terms)), suggester)], in: interaction, accepting: proposal)
            else { return }
            emit(interaction, .ownerAccepted(revision: 1))
            let held = sessions[interaction]?.heldConfirmation == true
            sessions[interaction]?.advance(to: .accepted(offer: offer))
            if held { await applyConfirmation(interaction) }
        case (.deciding, .pass):
            // Silence: the suggester only ever learns the plan stayed as it was.
            await finish(interaction, with: [.ownerPassed])
        default:
            throw ChangePlanError.unexpectedAnswer(interaction)
        }
    }

    /// The suggester takes it back: everyone already asked is told, so their
    /// cards close. The coordinator records the withdrawal itself.
    public func withdraw(_ interaction: InteractionID) async {
        guard let session = sessions[interaction] else { return }
        // Before the first suspension (review of PR #111, finding B): from
        // here no late yes or confirmation counts, and the notices go to
        // the offers sent so far.
        let open = session.step == .asking || session.step == .inviting || session.step == .committing
        let notices = session.role == .suggester && open ? session.withdrawals : []
        sessions[interaction]?.advance(to: .ending)
        cancelSends(of: interaction)
        if !notices.isEmpty { _ = await send(notices, in: interaction, failureEnds: false) }
        await finish(interaction, with: [])
    }

    // MARK: - Receiving

    public func handle(_ event: InboxEvent) async {
        if case .message(let envelope) = event, envelope.recipient == me, case .hello(let card) = envelope.body {
            cards[envelope.sender] = card
            return
        }
        guard case .message(let envelope) = event, let skill = envelope.skill, skill.id == descriptor.id,
              skill.version.isCompatible(with: descriptor.ref.version), envelope.recipient == me,
              let mode = envelope.mode, descriptor.sendModes.contains(mode),
              let planConversation = envelope.chainedFrom
        else { return }
        // Acknowledgments, and confirmations resent after this phone applied them.
        if await acknowledged(envelope) { return }
        if await reacknowledged(envelope) { return }
        guard !closed.contains(envelope.conversation) else { return }
        if let id = byConversation[envelope.conversation] {
            await receive(envelope, in: id)
            return
        }
        // Never a conversation the ledger has retired; a ledger that cannot
        // answer opens nothing.
        guard (try? await ledger.isRetired(envelope.conversation)) == false else { return }
        switch envelope.body {
        // A leave is its own message: an offer of nothing, naming the plan's
        // revision (review of PR #111, finding A).
        case .propose(let offer) where offer.terms.values.isEmpty: await left(envelope, notice: offer, planConversation: planConversation)
        case .propose(let offer): await offered(envelope, offer: offer, planConversation: planConversation)
        // A rejection only ever withdraws an offer it names; one that names
        // nothing open here is ignored, never taken for a leave.
        case .reject(let rejection): withdrawQueued(envelope, rejection: rejection, planConversation: planConversation)
        default: return
        }
    }

    private func offered(_ envelope: Envelope, offer: Proposal, planConversation: ConversationID) async {
        guard let current = await planLookup(planConversation) else {
            await invited(envelope, offer: offer, planConversation: planConversation)
            return
        }
        let plan = current.plan
        guard plan.origin == planConversation, plan.attendees.peers.contains(envelope.sender), plan.attendees.peers.contains(me),
              envelope.sender != me, UInt32(offer.round) == plan.revision,
              offer.inReplyTo == Self.rosterDigest(origin: planConversation, revision: plan.revision, suggester: envelope.sender,
                                                   asked: plan.attendees.peers.filter { $0 != envelope.sender }),
              let suggestion = PlanChange.suggestion(from: offer.terms, basis: plan)
        else { return }
        let proposed = suggestion.proposed
        // A suggestion whose window already closed (one that waited behind
        // another) is not shown.
        if let expires = offer.expiresAt?.date, expires <= now() { return }
        // Another message may have opened this conversation while we looked.
        guard byConversation[envelope.conversation] == nil, !closed.contains(envelope.conversation) else { return }
        // One suggestion at a time: this one waits for the open one to settle.
        if openByPlan[planConversation] != nil {
            if queued[planConversation, default: []].count < Self.maxQueued { queued[planConversation, default: []].append(envelope) }
            return
        }
        let id = InteractionID()
        sessions[id] = Session(
            role: .voter, conversation: envelope.conversation, planConversation: planConversation, planInteraction: current.interaction,
            basisRevision: plan.revision, basis: plan, proposed: proposed, suggester: envelope.sender, voters: [], friend: nil, terms: offer.terms,
            inviteTerms: nil, step: .deciding(offer: envelope.id, proposal: offer)
        )
        byConversation[envelope.conversation] = id
        openByPlan[planConversation] = id
        sessions[id]?.deadline = Self.deadline(for: offer, now: now())
        schedule(id, at: Self.deadline(for: offer, now: now()))
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: planConversation))
        emit(id, .proposalReady(SkillProposal(revision: 1, participants: proposed.attendees.peers, terms: offer.terms, plan: proposed)))
    }

    /// An invite to a plan this phone is not in: a friend is being added.
    private func invited(_ envelope: Envelope, offer: Proposal, planConversation: ConversationID) async {
        if let expires = offer.expiresAt?.date, expires <= now() { return }
        guard envelope.sender != me,
              let plan = PlanChange.invitedPlan(from: offer.terms, origin: planConversation, revision: UInt32(offer.round) + 1,
                                                sender: envelope.sender, me: me),
              byConversation[envelope.conversation] == nil, !closed.contains(envelope.conversation)
        else { return }
        let id = InteractionID()
        sessions[id] = Session(
            role: .joiner, conversation: envelope.conversation, planConversation: planConversation, planInteraction: nil,
            basisRevision: UInt32(offer.round), basis: nil, proposed: plan, suggester: envelope.sender, voters: [], friend: nil, terms: offer.terms,
            inviteTerms: nil, step: .deciding(offer: envelope.id, proposal: offer)
        )
        byConversation[envelope.conversation] = id
        sessions[id]?.deadline = Self.deadline(for: offer, now: now())
        schedule(id, at: Self.deadline(for: offer, now: now()))
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: planConversation))
        emit(id, .proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: offer.terms, plan: plan)))
    }

    /// Someone left the plan: a notice in a fresh conversation. It applies
    /// once, is acknowledged, and its conversation is retired before the
    /// note on the timeline ends. A notice resent after it applied (its
    /// acknowledgment was lost) is just acknowledged again.
    private func left(_ envelope: Envelope, notice offer: Proposal, planConversation: ConversationID) async {
        guard let noticeID = offer.inReplyTo, envelope.sender != me,
              byConversation[envelope.conversation] == nil, !closed.contains(envelope.conversation)
        else { return }
        // This departure applied already (its acknowledgment was lost): just
        // acknowledge it again. A later departure by the same person, after
        // they were added back, has a new ID and applies.
        if let known = departed[noticeID], known.peer == envelope.sender, known.planConversation == planConversation {
            await acknowledge(noticeID, to: envelope.sender, in: envelope.conversation, planConversation: planConversation, interaction: nil)
            await retire(envelope.conversation)
            return
        }
        // Bound to this plan, and to a revision this phone has reached: a
        // leaver ahead of this phone is waited for, as its resends will be.
        guard let current = await planLookup(planConversation), current.plan.origin == planConversation,
              current.plan.attendees.peers.contains(envelope.sender), UInt32(offer.round) <= current.plan.revision
        else { return }
        // Anything open for this plan included them: it cannot go through.
        await settle(planConversation: planConversation)
        let departure = Departure(id: UUID(), departure: noticeID, planConversation: planConversation, peer: envelope.sender,
                                  revision: current.plan.revision, until: resend.end(for: current.plan, now: now()))
        // Durable before it applies; if it cannot be, nothing happens and
        // the leaver's resend tries again (issue #117).
        guard await store(.departed(departure)) else { return }
        departed[noticeID] = departure
        startResending(departure.id)

        let id = InteractionID()
        let remaining = current.plan.attendees.peers.filter { $0 != envelope.sender }
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: planConversation))
        if remaining.count >= 2, let attendees = try? Attendees(remaining), let smaller = try? current.plan.updating(attendees: attendees) {
            continuation.yield(.produced(current.interaction, .plan(smaller)))
        } else if await retire(planConversation) {
            // Only this phone is left: the plan ends here too.
            emit(current.interaction, .withdrawn)
        }
        await acknowledge(noticeID, to: envelope.sender, in: envelope.conversation, planConversation: planConversation, interaction: id)
        if await retire(envelope.conversation) { emit(id, .withdrawn) } else { emit(id, .failed) }
    }

    /// The suggester withdrew an offer that was waiting behind another: it
    /// leaves the queue. Nothing else changes.
    private func withdrawQueued(_ envelope: Envelope, rejection: Rejection, planConversation: ConversationID) {
        queued[planConversation]?.removeAll { $0.conversation == envelope.conversation && $0.sender == envelope.sender && $0.id == rejection.proposal }
        if queued[planConversation]?.isEmpty == true { queued[planConversation] = nil }
    }

    private func receive(_ envelope: Envelope, in id: InteractionID) async {
        // Every reply is bound to this suggestion's plan as well as its
        // conversation, sender, and offer (issue #114).
        guard let session = sessions[id], envelope.chainedFrom == session.planConversation else { return }
        switch (session.role, session.step, envelope.body) {
        // Suggester: a yes from someone asked, naming the offer they got.
        case (.suggester, .asking, .accept(let acceptance)) where session.voters.contains(envelope.sender) && acceptance.terms == session.terms:
            await vote(acceptance.proposal, from: envelope.sender, in: id)
        case (.suggester, .inviting, .accept(let acceptance)) where envelope.sender == session.friend && acceptance.terms == session.inviteTerms:
            await vote(acceptance.proposal, from: envelope.sender, in: id)

        // Voter or joiner: a confirmation before our yes is recorded waits.
        case (.voter, .accepting(let offer), .accept(let confirmation)), (.joiner, .accepting(let offer), .accept(let confirmation)):
            guard envelope.sender == session.suggester, confirmation.proposal == offer, confirmation.terms.values.isEmpty else { return }
            sessions[id]?.heldConfirmation = true
        // Voter or joiner: the suggester's confirmation, naming our offer.
        case (.voter, .accepted(let offer), .accept(let confirmation)), (.joiner, .accepted(let offer), .accept(let confirmation)):
            guard envelope.sender == session.suggester, confirmation.proposal == offer, confirmation.terms.values.isEmpty else { return }
            await applyConfirmation(id)
        // The suggester withdrew it.
        case (.voter, .deciding(let offer, _), .reject(let rejection)), (.voter, .accepting(let offer), .reject(let rejection)),
             (.voter, .accepted(let offer), .reject(let rejection)),
             (.joiner, .deciding(let offer, _), .reject(let rejection)), (.joiner, .accepting(let offer), .reject(let rejection)),
             (.joiner, .accepted(let offer), .reject(let rejection)):
            guard envelope.sender == session.suggester, rejection.proposal == offer else { return }
            // Told at the window's end that it ends without agreement: the
            // card just closes, as if no yes had been given.
            let passed = session.deadline.map { now() >= $0 } ?? false
            await finish(id, with: [passed ? .expired : .noAgreement])
        default:
            return
        }
    }

    /// A yes counts only if it names the offer actually sent to that friend
    /// in this conversation; one that arrives before Outbox returned that
    /// offer's ID is held until it does.
    private func vote(_ proposal: MessageID, from peer: PeerID, in id: InteractionID) async {
        guard var session = sessions[id], session.step == .asking || session.step == .inviting else { return }
        guard let sent = session.offers[peer] else {
            session.early[peer] = proposal
            sessions[id] = session
            return
        }
        guard sent == proposal else { return }
        session.yes.insert(peer)
        sessions[id] = session
        await progress(id)
    }

    /// Records an offer's ID as its send returns, and counts a yes that was
    /// waiting for it.
    private func recordOffer(_ envelope: Envelope, in id: InteractionID) async {
        guard var session = sessions[id], session.role == .suggester else { return }
        session.offers[envelope.recipient] = envelope.id
        let early = session.early.removeValue(forKey: envelope.recipient)
        sessions[id] = session
        if let early { await vote(early, from: envelope.recipient, in: id) }
    }

    private func progress(_ id: InteractionID) async {
        guard let session = sessions[id], session.role == .suggester else { return }
        switch session.step {
        case .asking where Set(session.voters).isSubset(of: session.yes):
            // The plan must still be the one the suggestion changes, before
            // the friend is invited or anything is confirmed (finding C).
            guard await basisStands(id) else { return }
            if let friend = session.friend, let inviteTerms = session.inviteTerms {
                sessions[id]?.advance(to: .inviting)
                guard let invite = try? Proposal(round: UInt16(session.basisRevision), terms: inviteTerms,
                                                 expiresAt: deadlines[id].map { Timestamp($0) })
                else { return }
                _ = await send([(.propose(invite), friend)], in: id, recordOffers: true)
            } else {
                await confirm(id)
            }
        case .inviting where session.friend.map(session.yes.contains) == true:
            guard await basisStands(id) else { return }
            await confirm(id)
        default:
            return
        }
    }

    /// Everyone said yes. The change is agreed: it applies here at once, and
    /// a confirmation goes to each person, resent until each acknowledges it
    /// (ADR 0243). The suggester's change ends planned, which is not an
    /// ending, so its conversation stays open for the acknowledgments and is
    /// retired when the delivery is done.
    private func confirm(_ id: InteractionID) async {
        guard let session = sessions[id], session.step == .asking || session.step == .inviting else { return }
        // Committing, before the first suspension (finding 2): a withdrawal
        // or the window from here aborts the commit instead.
        sessions[id]?.advance(to: .committing)
        guard let step = sessions[id]?.stepID else { return }
        let order = session.asked.filter { session.offers[$0] != nil }
        let delivery = ConfirmationDelivery(
            interaction: id, conversation: session.conversation, planConversation: session.planConversation,
            plan: session.proposed, planInteraction: session.planInteraction, order: order,
            pending: Dictionary(uniqueKeysWithValues: order.map { ($0, session.offers[$0]!) }),
            until: resend.end(for: session.proposed, now: now())
        )
        // The agreed plan and who is owed what, durable before anything is
        // published or sent (finding 3, issue #117). If it cannot be, the
        // plan stays as it was.
        guard await store(.confirming(delivery)) else {
            await abandon(id)
            return
        }
        // Still ours, and the plan still stands as the basis.
        let current = await planLookup(session.planConversation)
        guard sessions[id]?.stepID == step else {
            await forget(id.rawValue)
            return
        }
        guard let current, current.plan.revision == session.basis?.revision, current.plan.attendees == session.basis?.attendees else {
            await forget(id.rawValue)
            await abandon(id)
            return
        }
        // What each acknowledgment must name, before any confirmation is sent (#105).
        confirming[id] = delivery
        confirmingByConversation[session.conversation] = id
        await close(id)
        emit(id, .everyoneConfirmed(revision: 1))
        if let plan = session.planInteraction { continuation.yield(.produced(plan, .plan(session.proposed))) }
        await resendOnce(id.rawValue)
        startResending(id.rawValue)
        await dequeue(session.planConversation)
    }

    /// A voter or joiner got the confirmation. It applies only if it changes
    /// the plan as it stands (or was already applied). What it applies is
    /// journaled first, then announced, then acknowledged, and kept so a
    /// resent one is acknowledged again; a restart replays it if the update
    /// never became durable. If the journal cannot record it, nothing
    /// happens and the suggester's resend tries again (issue #117). One for
    /// a revision that does not follow this phone's is ignored.
    private func applyConfirmation(_ id: InteractionID) async {
        guard let session = sessions[id], case .accepted(let offer) = session.step, let suggester = session.suggester else { return }
        let step = session.stepID
        var update: SkillEvent?
        if let planInteraction = session.planInteraction {
            guard let current = await planLookup(session.planConversation) else { return }
            if current.plan.revision == session.basisRevision, current.plan.attendees == session.basis?.attendees {
                update = .produced(planInteraction, .plan(session.proposed))
            } else if current.plan.revision == session.proposed.revision, current.plan.attendees == session.proposed.attendees,
                      current.plan.time == session.proposed.time, current.plan.activity == session.proposed.activity {
                update = nil
            } else {
                return
            }
        } else {
            // A friend being added: this interaction now holds the plan.
            update = .produced(id, .plan(session.proposed))
        }
        let receipt = AppliedConfirmation(interaction: id, conversation: session.conversation, planConversation: session.planConversation,
                                          suggester: suggester, offer: offer, plan: session.proposed, planInteraction: session.planInteraction,
                                          basisRevision: session.basisRevision, until: resend.end(for: session.proposed, now: now()))
        guard await store(.applied(receipt)), sessions[id]?.stepID == step else { return }
        journaledYes.remove(id)
        applied[session.conversation] = receipt
        emit(id, .everyoneConfirmed(revision: 1))
        if let update { continuation.yield(update) }
        await close(id)
        await acknowledge(offer, to: suggester, in: session.conversation, planConversation: session.planConversation, interaction: id)
        startResending(id.rawValue)
        await dequeue(session.planConversation)
    }

    /// Ends a session that is settled without an ending (the change applies),
    /// keeping its conversation open for acknowledgments.
    private func close(_ id: InteractionID) async {
        cancelSends(of: id)
        timers.removeValue(forKey: id)?.cancel()
        deadlines[id] = nil
        guard let session = sessions.removeValue(forKey: id) else { return }
        byConversation[session.conversation] = nil
        if openByPlan[session.planConversation] == id { openByPlan[session.planConversation] = nil }
        // The change is over on this phone (ADR 0023).
        await holds.release(session.planConversation, for: session.conversation)
    }

    // MARK: - Windows

    private var deadlines: [InteractionID: Date] = [:]

    private static func deadline(for offer: Proposal, now: Date) -> Date {
        let latest = now.addingTimeInterval(24 * 3600)
        guard let expires = offer.expiresAt?.date else { return now.addingTimeInterval(2 * 3600) }
        return min(expires, latest)
    }

    private func schedule(_ id: InteractionID, at deadline: Date) {
        deadlines[id] = deadline
        let sleep = self.sleep
        timers[id] = Task { [weak self] in
            do { try await sleep(deadline) } catch { return }
            await self?.windowClosed(id)
        }
    }

    /// Nothing changes. The suggester's card says the plan stays as it was;
    /// everyone else's card just closes.
    private func windowClosed(_ id: InteractionID) async {
        guard let session = sessions[id] else { return }
        switch session.step {
        case .accepting, .accepted:
            // Said yes: the confirmation may still come, resent, until its
            // delivery ends (finding 1), as long as it could still apply.
            if let until = session.holdUntil, now() < until, await couldStillApply(session) {
                schedule(id, at: until)
                return
            }
            await finish(id, with: [.expired])
        case .committing, .ending:
            return
        default:
            // The suggester tells everyone asked, so cards that said yes close.
            if session.role == .suggester { await abandon(id) } else { await finish(id, with: [.expired]) }
        }
    }

    /// Ends whatever is open for a plan (its people changed), quietly.
    private func settle(planConversation: ConversationID) async {
        guard let id = openByPlan[planConversation], let session = sessions[id], session.step != .ending else { return }
        let notices = session.role == .suggester ? session.withdrawals : []
        sessions[id]?.advance(to: .ending)
        cancelSends(of: id)
        queued[planConversation] = nil
        if !notices.isEmpty { _ = await send(notices, in: id, failureEnds: false) }
        await finish(id, with: [.noAgreement])
    }

    /// Whether the plan still stands as the suggestion's basis. If another
    /// skill changed it (Pick a place moved it on a revision), the
    /// suggestion ends as "The plan stays as it was" and everyone asked is
    /// told. False also if the suggestion moved on while the plan was read.
    private func basisStands(_ id: InteractionID) async -> Bool {
        guard let session = sessions[id], let basis = session.basis else { return false }
        let step = session.stepID
        let current = await planLookup(session.planConversation)
        guard sessions[id]?.stepID == step else { return false }
        if let current, current.plan.revision == basis.revision, current.plan.attendees == basis.attendees { return true }
        await abandon(id)
        return false
    }

    /// Ends an open suggestion or card quietly, the plan as it was: the
    /// suggester tells everyone asked (from a snapshot taken before any
    /// suspension) and its card reads "The plan stays as it was".
    private func abandon(_ id: InteractionID) async {
        guard let session = sessions[id], session.step != .ending else { return }
        let notices = session.role == .suggester ? session.withdrawals : []
        sessions[id]?.advance(to: .ending)
        cancelSends(of: id)
        if !notices.isEmpty { _ = await send(notices, in: id, failureEnds: false) }
        await finish(id, with: [.noAgreement])
    }

    /// Another skill changed the plan (the coordinator calls this after it
    /// applies any plan update): a suggestion or card open for it whose
    /// basis no longer stands ends at once (review of PR #111, finding C).
    public func planDidChange(_ planConversation: ConversationID) async {
        guard let id = openByPlan[planConversation], let session = sessions[id], session.step != .ending, session.basis != nil else { return }
        _ = await basisStands(id)
    }

    // MARK: - Restart

    /// A yes, a commit, an applied change, a leave, and a departure come back
    /// from the journal (and a commit or update the crash interrupted is
    /// replayed). Any other open suggestion cannot be resumed (its offers'
    /// IDs are not stored): it is retired and reported failed, and the plan
    /// stays as it was. Ended ones are retired again, in case the app quit
    /// first.
    public func restore(_ interactions: [Interaction]) async {
        await retryRetirements()
        let recovered = await recoverJournal(interactions)
        for interaction in interactions where interaction.skill.id == descriptor.id && !recovered.contains(interaction.id) {
            if interaction.state.isFinal {
                await retire(interaction.conversation)
            } else if interaction.state != .drafting && interaction.state != .planned {
                if await retire(interaction.conversation) { emit(interaction.id, .failed) }
            }
        }
    }

    public func shutdown() async {
        for tasks in inFlight.values { for task in tasks.values { task.cancel() } }
        for timer in timers.values { timer.cancel() }
        for task in deliveryTasks.values { task.cancel() }
        inFlight = [:]
        timers = [:]
        deliveryTasks = [:]
        continuation.finish()
    }

    // MARK: - Reliable confirmations and leave notices (ADR 0243)

    @discardableResult
    private func store(_ record: ChangePlanRecord) async -> Bool {
        do {
            try await journal.save(record)
            return true
        } catch {
            journalFailures += 1
            return false
        }
    }

    private func forget(_ key: UUID) async {
        do { try await journal.remove(key) } catch { journalFailures += 1 }
    }

    /// A value-free acknowledgment that names what it acknowledges.
    private func acknowledge(_ names: MessageID, to peer: PeerID, in conversation: ConversationID, planConversation: ConversationID,
                             interaction: InteractionID?) async {
        _ = try? await outbox.send(.accept(Acceptance(proposal: names, terms: Terms.empty)), to: peer, conversation: conversation,
                                   recipientCard: cards[peer], context: OutboundContext(interaction: interaction),
                                   skill: descriptor.ref, mode: .invite, chainedFrom: planConversation)
    }

    /// An acknowledgment of a confirmation or leave notice this phone sent.
    /// It counts only if it names what was sent to that person.
    private func acknowledged(_ envelope: Envelope) async -> Bool {
        guard case .accept(let ack) = envelope.body, ack.terms.values.isEmpty else { return false }
        if let id = confirmingByConversation[envelope.conversation], var delivery = confirming[id] {
            guard envelope.chainedFrom == delivery.planConversation else { return true }
            if delivery.pending[envelope.sender] == ack.proposal {
                delivery.pending[envelope.sender] = nil
                confirming[id] = delivery
                await progressDelivery(.confirming(delivery))
            }
            return true
        }
        for (id, var delivery) in leaving where delivery.pending.contains(envelope.sender) && ack.proposal == delivery.departure
            && envelope.chainedFrom == delivery.planConversation {
            delivery.pending.remove(envelope.sender)
            leaving[id] = delivery
            await progressDelivery(.leaving(delivery))
            return true
        }
        return false
    }

    /// A confirmation resent after this phone applied it: acknowledged again,
    /// and nothing changes.
    private func reacknowledged(_ envelope: Envelope) async -> Bool {
        guard let receipt = applied[envelope.conversation] else { return false }
        if case .accept(let confirmation) = envelope.body, confirmation.terms.values.isEmpty, envelope.sender == receipt.suggester,
           envelope.chainedFrom == receipt.planConversation,
           confirmation.proposal == receipt.offer {
            // Acknowledged only once the plan shows the change; otherwise it
            // is replayed first and acknowledged on the next resend (finding 3).
            if await planShows(receipt) {
                await acknowledge(receipt.offer, to: receipt.suggester, in: receipt.conversation, planConversation: receipt.planConversation,
                                  interaction: receipt.interaction)
            } else {
                await replay(receipt)
            }
        }
        return true
    }

    /// Whether a confirmation for this card could still apply: the plan
    /// still stands at the card's basis (a friend being added has none).
    private func couldStillApply(_ session: Session) async -> Bool {
        guard let basis = session.basis else { return true }
        guard let current = await planLookup(session.planConversation) else { return false }
        return current.plan.revision == basis.revision && current.plan.attendees == basis.attendees
    }

    /// Whether this phone's plan already shows an applied change.
    private func planShows(_ receipt: AppliedConfirmation) async -> Bool {
        guard let current = await planLookup(receipt.planConversation) else { return false }
        return current.plan.revision >= receipt.plan.revision
    }

    /// Publishes an applied change again, if the plan still stands where the
    /// change found it (the update was lost before it became durable).
    private func replay(_ receipt: AppliedConfirmation) async {
        let current = await planLookup(receipt.planConversation)
        if let holder = receipt.planInteraction {
            guard let current, current.plan.revision == receipt.basisRevision else { return }
            continuation.yield(.produced(holder, .plan(receipt.plan)))
        } else if current == nil {
            continuation.yield(.produced(receipt.interaction, .plan(receipt.plan)))
        }
    }

    /// Saves a delivery's progress; one that everyone acknowledged is done.
    private func progressDelivery(_ record: ChangePlanRecord) async {
        switch record {
        case .confirming(let delivery) where delivery.pending.isEmpty: await endDelivery(record.key)
        case .leaving(let delivery) where delivery.pending.isEmpty: await endDelivery(record.key)
        default: await store(record)
        }
    }

    /// Each leave notice goes in a fresh conversation, naming the
    /// departure's one ID, so a friend can close it at once.
    private func sendLeaveNotices(_ id: InteractionID) async {
        guard let delivery = leaving[id] else { return }
        // Nothing offered: the plan's origin (chainedFrom) and the revision
        // left at (round) bind it; inReplyTo is the departure.
        let round = UInt16(min(delivery.revision, UInt32(ProtocolLimits.maxNegotiationRounds - 1)))
        guard let body = try? Proposal(round: round, terms: Terms.empty, inReplyTo: delivery.departure) else { return }
        for peer in delivery.order where leaving[id]?.pending.contains(peer) == true {
            _ = try? await outbox.send(.propose(body), to: peer, conversation: ConversationID(),
                                       recipientCard: cards[peer], context: OutboundContext(interaction: id),
                                       skill: descriptor.ref, mode: .invite, chainedFrom: delivery.planConversation)
        }
    }

    /// One more round of whatever a record still owes.
    private func resendOnce(_ key: UUID) async {
        let id = InteractionID(key)
        if let delivery = confirming[id] {
            for peer in delivery.order {
                guard let offer = confirming[id]?.pending[peer] else { continue }
                _ = try? await outbox.send(.accept(Acceptance(proposal: offer, terms: Terms.empty)), to: peer, conversation: delivery.conversation,
                                           recipientCard: cards[peer], context: OutboundContext(interaction: id),
                                           skill: descriptor.ref, mode: .invite, chainedFrom: delivery.planConversation)
            }
        } else if leaving[id] != nil {
            await sendLeaveNotices(id)
        }
    }

    /// When a record's window ends, if it is still here.
    private func until(_ key: UUID) -> Date? {
        let id = InteractionID(key)
        if let delivery = confirming[id] { return delivery.until }
        if let delivery = leaving[id] { return delivery.until }
        if let receipt = applied.values.first(where: { $0.interaction == id }) { return receipt.until }
        return departed.values.first { $0.id == key }?.until
    }

    /// Resends on the schedule until everyone acknowledged or the window
    /// ends; a record that only waits (applied, departed) just waits.
    private func startResending(_ key: UUID) {
        deliveryTasks[key]?.cancel()
        deliveryTasks[key] = Task { [weak self] in await self?.runDelivery(key) }
    }

    private func runDelivery(_ key: UUID) async {
        var wait = resend.firstRetry
        while !Task.isCancelled, let end = until(key) {
            let next = min(now().addingTimeInterval(wait), end)
            do { try await sleep(next) } catch { return }
            guard until(key) != nil else { return }
            if now() >= end {
                // Ending from inside the loop: it must not cancel itself.
                deliveryTasks[key] = nil
                await endDelivery(key)
                return
            }
            await resendOnce(key)
            wait = min(wait * 2, resend.maxBackoff)
        }
    }

    /// A record is done (everyone acknowledged) or its window ended: it is
    /// removed, and a conversation kept open for it is retired. None of
    /// these is an ending of an interaction, so nothing is announced.
    private func endDelivery(_ key: UUID) async {
        let id = InteractionID(key)
        let task = deliveryTasks.removeValue(forKey: key)
        if let delivery = confirming.removeValue(forKey: id) {
            confirmingByConversation[delivery.conversation] = nil
            await forget(key)
            await retire(delivery.conversation)
        } else if leaving.removeValue(forKey: id) != nil {
            await forget(key)
        } else if let receipt = applied.values.first(where: { $0.interaction == id }) {
            applied[receipt.conversation] = nil
            await forget(key)
            await retire(receipt.conversation)
        } else {
            if let departure = departed.values.first(where: { $0.id == key }) {
                departed[departure.departure] = nil
                await forget(key)
            }
        }
        task?.cancel()
    }

    /// At launch: everything still owed or kept comes back, and resending
    /// picks up where it was (at once, then on the schedule).
    private func recoverJournal(_ interactions: [Interaction]) async -> Set<InteractionID> {
        let records: [ChangePlanRecord]
        do { records = try await journal.records() } catch {
            journalFailures += 1
            return []
        }
        let states = Dictionary(interactions.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        var recovered: Set<InteractionID> = []
        for record in records {
            switch record {
            case .accepted(let yes):
                guard yes.until > now(), states[yes.interaction].map({ !$0.isFinal && $0 != .planned }) ?? false else {
                    await forget(record.key)
                    continue
                }
                // The card waits for its confirmation again.
                sessions[yes.interaction] = Session(
                    role: yes.joining ? .joiner : .voter, conversation: yes.conversation, planConversation: yes.planConversation,
                    planInteraction: yes.planInteraction, basisRevision: yes.basis?.revision ?? (yes.proposed.revision - 1), basis: yes.basis,
                    proposed: yes.proposed, suggester: yes.suggester, voters: [], friend: nil, terms: Terms.empty, inviteTerms: nil,
                    step: .accepted(offer: yes.offer), holdUntil: yes.until
                )
                byConversation[yes.conversation] = yes.interaction
                if !yes.joining { openByPlan[yes.planConversation] = yes.interaction }
                journaledYes.insert(yes.interaction)
                schedule(yes.interaction, at: yes.until)
                recovered.insert(yes.interaction)
                // Held again (ADR 0023 decision 5). If another change holds
                // the plan, this one ends and the plan stays as it was.
                if await !holds.hold(yes.planConversation, for: yes.conversation) {
                    await finish(yes.interaction, with: [.noAgreement])
                }
                continue
            case .confirming(let delivery):
                confirming[delivery.interaction] = delivery
                confirmingByConversation[delivery.conversation] = delivery.interaction
                recovered.insert(delivery.interaction)
                // Finish a commit the crash interrupted (finding 3).
                if let state = states[delivery.interaction], !state.isFinal, state != .planned { emit(delivery.interaction, .everyoneConfirmed(revision: 1)) }
                if let holder = delivery.planInteraction, let current = await planLookup(delivery.planConversation),
                   current.plan.revision + 1 == delivery.plan.revision {
                    continuation.yield(.produced(holder, .plan(delivery.plan)))
                }
            case .applied(let receipt):
                applied[receipt.conversation] = receipt
                recovered.insert(receipt.interaction)
                if let state = states[receipt.interaction], !state.isFinal, state != .planned { emit(receipt.interaction, .everyoneConfirmed(revision: 1)) }
                if await !planShows(receipt) { await replay(receipt) }
            case .leaving(let delivery):
                leaving[delivery.interaction] = delivery
                recovered.insert(delivery.interaction)
            case .departed(let departure):
                departed[departure.departure] = departure
                // A departure applied but never made durable is applied again.
                if let current = await planLookup(departure.planConversation), current.plan.revision == departure.revision,
                   current.plan.attendees.peers.contains(departure.peer) {
                    let remaining = current.plan.attendees.peers.filter { $0 != departure.peer }
                    if remaining.count >= 2, let attendees = try? Attendees(remaining), let smaller = try? current.plan.updating(attendees: attendees) {
                        continuation.yield(.produced(current.interaction, .plan(smaller)))
                    } else if await retire(departure.planConversation) {
                        emit(current.interaction, .withdrawn)
                    }
                }
            }
            if record.until <= now() {
                await endDelivery(record.key)
            } else {
                await resendOnce(record.key)
                startResending(record.key)
            }
        }
        return recovered
    }

    // MARK: - Sending

    /// Sends in order, in a task tracked per interaction so a withdrawal or
    /// ending cancels it. Returns whether every message went out with the
    /// interaction still at the step it was sent for. A failure ends the
    /// interaction only if that step is still current (ADR 0011 amendment
    /// 14) and `failureEnds`.
    private func send(_ messages: [(MessageBody, PeerID)], in id: InteractionID, accepting: Proposal? = nil, recordOffers: Bool = false,
                      failureEnds: Bool = true) async -> Bool {
        guard let session = sessions[id] else { return false }
        let outbox = outbox
        let skill = descriptor.ref
        let step = session.stepID
        let task = Task { [weak self] in
            for (body, peer) in messages {
                try Task.checkCancellation()
                let envelope = try await outbox.send(body, to: peer, conversation: session.conversation, recipientCard: await self?.card(for: peer),
                                                     context: OutboundContext(interaction: id, accepting: accepting),
                                                     skill: skill, mode: .invite, chainedFrom: session.planConversation)
                if recordOffers { await self?.recordOffer(envelope, in: id) }
            }
        }
        let key = UUID()
        inFlight[id, default: [:]][key] = task
        defer {
            inFlight[id]?[key] = nil
            if inFlight[id]?.isEmpty == true { inFlight[id] = nil }
        }
        do {
            try await task.value
            return sessions[id]?.stepID == step
        } catch {
            guard !task.isCancelled, failureEnds, let current = sessions[id], current.stepID == step else { return false }
            let event: InteractionEvent? = switch error {
            case OutboxError.consentDeclined: nil
            case OutboxError.denied: .blockedByPrivacy
            default: .failed
            }
            await finish(id, with: event.map { [$0] } ?? [])
            return false
        }
    }

    private func card(for peer: PeerID) -> AgentCard? { cards[peer] }

    private func cancelSends(of id: InteractionID) {
        if let tasks = inFlight.removeValue(forKey: id) { for task in tasks.values { task.cancel() } }
    }

    // MARK: - Endings

    /// Cancels the interaction's sends and window, retires its conversation,
    /// and only then publishes `events` and `extra`. If the ledger cannot
    /// record the retirement, the ending is reported as failed and nothing
    /// else is announced. A suggestion queued behind this one is looked at
    /// next.
    private func finish(_ id: InteractionID, with events: [InteractionEvent], then extra: [SkillEvent] = []) async {
        cancelSends(of: id)
        timers.removeValue(forKey: id)?.cancel()
        deadlines[id] = nil
        guard let session = sessions.removeValue(forKey: id) else { return }
        byConversation[session.conversation] = nil
        if openByPlan[session.planConversation] == id { openByPlan[session.planConversation] = nil }
        // Every ending releases the plan (ADR 0023).
        await holds.release(session.planConversation, for: session.conversation)
        if journaledYes.remove(id) != nil { await forget(id.rawValue) }
        let retired = await retire(session.conversation)
        if retired {
            for event in events { emit(id, event) }
            for event in extra { continuation.yield(event) }
        } else if !events.isEmpty {
            emit(id, .failed)
        }
        await dequeue(session.planConversation)
    }

    private func dequeue(_ planConversation: ConversationID) async {
        guard openByPlan[planConversation] == nil, var waiting = queued[planConversation], !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        queued[planConversation] = waiting.isEmpty ? nil : waiting
        // Looked at again against the plan as it stands now: one that names
        // an older revision is dropped.
        await handle(.message(next))
    }

    @discardableResult
    private func retire(_ conversation: ConversationID) async -> Bool {
        closed.insert(conversation)
        await retryRetirements()
        do {
            try await outbox.retire(conversation)
            unretired.remove(conversation)
            return true
        } catch {
            retireFailures += 1
            unretired.insert(conversation)
            return false
        }
    }

    /// Tries again every retirement the ledger could not record.
    public func retryRetirements() async {
        for conversation in unretired {
            do {
                try await outbox.retire(conversation)
                unretired.remove(conversation)
            } catch {
                retireFailures += 1
            }
        }
    }

    public var unretiredConversations: Set<ConversationID> { unretired }

    private func emit(_ id: InteractionID, _ event: InteractionEvent) {
        continuation.yield(.lifecycle(id, event))
    }
}

extension ChangePlanService {
    /// Names the plan, its revision, the suggester, and everyone asked,
    /// without disclosing anything a receiver does not already hold. A
    /// receiver computes it from its own plan; a suggestion put to fewer
    /// people than everyone else in the plan does not match.
    public static func rosterDigest(origin: ConversationID, revision: UInt32, suggester: PeerID, asked: [PeerID]) -> MessageID {
        var hasher = SHA256()
        hasher.update(data: Data("starling.change_plan.asked.v1".utf8))
        withUnsafeBytes(of: origin.rawValue.uuid) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: revision.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: suggester.bytes)
        for peer in asked.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) { hasher.update(data: peer.bytes) }
        let digest = Array(hasher.finalize())
        let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                               digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        return MessageID(uuid)
    }
}

extension Terms {
    static let empty = try! Terms([:])
}
