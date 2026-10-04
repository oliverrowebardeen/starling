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
    /// A suggestion for this plan is already open (ADR 0022 decision 6).
    case planBusy
    /// The request's people are not the plan's.
    case notInThePlan
    case alreadyStarted(InteractionID)
    case unknownInteraction(InteractionID)
    case unexpectedAnswer(InteractionID)
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
        /// Voter or joiner: said yes; waiting for the suggester's confirmation.
        case accepted(offer: MessageID)
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
    private var departed: [ConversationID: [PeerID: Departure]] = [:]
    /// Resend loops and end-of-window cleanups, by record key.
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Journal writes that failed. Delivery goes on; only a restart could lose it.
    public private(set) var journalFailures = 0
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
    public init(outbox: Outbox, ledger: any ConversationLedger, journal: any ChangePlanJournal, me: PeerID,
                planLookup: @escaping @Sendable (ConversationID) async -> PlanRef?, resend: ResendSchedule = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Date) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow))) }) {
        self.outbox = outbox
        self.ledger = ledger
        self.journal = journal
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
            await leave(request, plan: current, others: others)
            return
        }
        guard openByPlan[planConversation] == nil else { throw ChangePlanError.planBusy }
        guard basis.revision < UInt32(ProtocolLimits.maxNegotiationRounds - 1) else { throw ChangePlanError.stale }
        let proposed = try change.applied(to: basis)
        let terms = try change.terms(for: basis)
        var friend: PeerID?
        if case .change(_, _, let adding) = change { friend = adding }
        let deadline = request.intent.expiresAt.date

        // Everything a reply is matched against, before any send (#105).
        sessions[request.interaction] = Session(
            role: .suggester, conversation: request.conversation, planConversation: planConversation, planInteraction: current.interaction,
            basisRevision: basis.revision, proposed: proposed, suggester: nil, voters: others, friend: friend, terms: terms,
            inviteTerms: friend == nil ? nil : try PlanChange.inviteTerms(for: proposed), step: .asking
        )
        byConversation[request.conversation] = request.interaction
        openByPlan[planConversation] = request.interaction
        schedule(request.interaction, at: deadline)

        // The suggestion is the owner's own yes.
        emit(request.interaction, .proposalReady(SkillProposal(revision: 1, participants: proposed.attendees.peers, terms: terms, plan: proposed)))
        emit(request.interaction, .ownerAccepted(revision: 1))

        let offer = try Proposal(round: UInt16(basis.revision), terms: terms, expiresAt: request.intent.expiresAt)
        _ = await send(others.map { (MessageBody.propose(offer), $0) }, in: request.interaction, recordOffers: true)
    }

    /// Leaving: tell everyone else, then end this phone's plan. Nothing is
    /// disclosed but that the owner left. The notices are resent until each
    /// person acknowledges them, so every other phone's plan shrinks.
    private func leave(_ request: SkillRequest, plan: PlanRef, others: [PeerID]) async {
        sessions[request.interaction] = Session(
            role: .suggester, conversation: request.conversation, planConversation: plan.plan.origin, planInteraction: plan.interaction,
            basisRevision: plan.plan.revision, proposed: plan.plan, suggester: nil, voters: others, friend: nil, terms: Terms.empty,
            inviteTerms: nil, step: .asking
        )
        byConversation[request.conversation] = request.interaction
        let delivery = LeaveDelivery(interaction: request.interaction, planConversation: plan.plan.origin, order: others,
                                     pending: Dictionary(uniqueKeysWithValues: others.map { ($0, []) }), until: resend.end(for: plan.plan, now: now()))
        leaving[request.interaction] = delivery
        await store(.leaving(delivery))
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
            // Registered before the send: the confirmation names this offer.
            sessions[interaction]?.advance(to: .accepted(offer: offer))
            guard await send([(.accept(Acceptance(proposal: offer, terms: proposal.terms)), suggester)], in: interaction, accepting: proposal)
            else { return }
            emit(interaction, .ownerAccepted(revision: 1))
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
        cancelSends(of: interaction)
        if session.role == .suggester, session.step == .asking || session.step == .inviting {
            _ = await send(session.withdrawals, in: interaction)
        }
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
        case .propose(let offer): await offered(envelope, offer: offer, planConversation: planConversation)
        case .reject: await left(envelope, planConversation: planConversation)
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
            basisRevision: plan.revision, proposed: proposed, suggester: envelope.sender, voters: [], friend: nil, terms: offer.terms,
            inviteTerms: nil, step: .deciding(offer: envelope.id, proposal: offer)
        )
        byConversation[envelope.conversation] = id
        openByPlan[planConversation] = id
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
            basisRevision: UInt32(offer.round), proposed: plan, suggester: envelope.sender, voters: [], friend: nil, terms: offer.terms,
            inviteTerms: nil, step: .deciding(offer: envelope.id, proposal: offer)
        )
        byConversation[envelope.conversation] = id
        schedule(id, at: Self.deadline(for: offer, now: now()))
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: planConversation))
        emit(id, .proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: offer.terms, plan: plan)))
    }

    /// Someone left the plan: a notice in a fresh conversation. It applies
    /// once, is acknowledged, and its conversation is retired before the
    /// note on the timeline ends. A notice resent after it applied (its
    /// acknowledgment was lost) is just acknowledged again.
    private func left(_ envelope: Envelope, planConversation: ConversationID) async {
        guard case .reject(let notice) = envelope.body, envelope.sender != me,
              byConversation[envelope.conversation] == nil, !closed.contains(envelope.conversation)
        else { return }
        if departed[planConversation]?[envelope.sender] != nil {
            await acknowledge(notice.proposal, to: envelope.sender, in: envelope.conversation, planConversation: planConversation, interaction: nil)
            await retire(envelope.conversation)
            return
        }
        guard let current = await planLookup(planConversation), current.plan.origin == planConversation,
              current.plan.attendees.peers.contains(envelope.sender)
        else { return }
        // Anything open for this plan included them: it cannot go through.
        await settle(planConversation: planConversation)
        let departure = Departure(id: UUID(), planConversation: planConversation, peer: envelope.sender,
                                  until: resend.end(for: current.plan, now: now()))
        departed[planConversation, default: [:]][envelope.sender] = departure
        await store(.departed(departure))
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
        await acknowledge(notice.proposal, to: envelope.sender, in: envelope.conversation, planConversation: planConversation, interaction: id)
        if await retire(envelope.conversation) { emit(id, .withdrawn) } else { emit(id, .failed) }
    }

    private func receive(_ envelope: Envelope, in id: InteractionID) async {
        guard let session = sessions[id] else { return }
        switch (session.role, session.step, envelope.body) {
        // Suggester: a yes from someone asked, naming the offer they got.
        case (.suggester, .asking, .accept(let acceptance)) where session.voters.contains(envelope.sender) && acceptance.terms == session.terms:
            await vote(acceptance.proposal, from: envelope.sender, in: id)
        case (.suggester, .inviting, .accept(let acceptance)) where envelope.sender == session.friend && acceptance.terms == session.inviteTerms:
            await vote(acceptance.proposal, from: envelope.sender, in: id)

        // Voter or joiner: the suggester's confirmation, naming our offer.
        case (.voter, .accepted(let offer), .accept(let confirmation)), (.joiner, .accepted(let offer), .accept(let confirmation)):
            guard envelope.sender == session.suggester, confirmation.proposal == offer, confirmation.terms.values.isEmpty else { return }
            await applyConfirmation(id)
        // The suggester withdrew it.
        case (.voter, .deciding(let offer, _), .reject(let rejection)), (.voter, .accepted(let offer), .reject(let rejection)),
             (.joiner, .deciding(let offer, _), .reject(let rejection)), (.joiner, .accepted(let offer), .reject(let rejection)):
            guard envelope.sender == session.suggester, rejection.proposal == offer else { return }
            await finish(id, with: [.noAgreement])
        default:
            return
        }
    }

    /// A yes counts only if it names the offer actually sent to that friend
    /// in this conversation; one that arrives before Outbox returned that
    /// offer's ID is held until it does.
    private func vote(_ proposal: MessageID, from peer: PeerID, in id: InteractionID) async {
        guard var session = sessions[id] else { return }
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
        guard let session = sessions[id] else { return }
        let order = session.asked.filter { session.offers[$0] != nil }
        let delivery = ConfirmationDelivery(
            interaction: id, conversation: session.conversation, planConversation: session.planConversation, order: order,
            pending: Dictionary(uniqueKeysWithValues: order.map { ($0, session.offers[$0]!) }),
            until: resend.end(for: session.proposed, now: now())
        )
        // What each acknowledgment must name, before any confirmation is sent (#105).
        confirming[id] = delivery
        confirmingByConversation[session.conversation] = id
        await store(.confirming(delivery))
        close(id)
        emit(id, .everyoneConfirmed(revision: 1))
        if let plan = session.planInteraction { continuation.yield(.produced(plan, .plan(session.proposed))) }
        await resendOnce(id.rawValue)
        startResending(id.rawValue)
        await dequeue(session.planConversation)
    }

    /// A voter or joiner got the confirmation. It applies only if it changes
    /// the plan as it stands (or was already applied); it is then
    /// acknowledged, and kept so a resent one is acknowledged again. One for
    /// a revision that does not follow this phone's is ignored.
    private func applyConfirmation(_ id: InteractionID) async {
        guard let session = sessions[id], case .accepted(let offer) = session.step, let suggester = session.suggester else { return }
        if let planInteraction = session.planInteraction {
            guard let current = await planLookup(session.planConversation) else { return }
            if current.plan.revision == session.basisRevision {
                emit(id, .everyoneConfirmed(revision: 1))
                continuation.yield(.produced(planInteraction, .plan(session.proposed)))
            } else if current.plan.revision == session.proposed.revision, current.plan.attendees == session.proposed.attendees,
                      current.plan.time == session.proposed.time, current.plan.activity == session.proposed.activity {
                emit(id, .everyoneConfirmed(revision: 1))
            } else {
                return
            }
        } else {
            // A friend being added: this interaction now holds the plan.
            emit(id, .everyoneConfirmed(revision: 1))
            continuation.yield(.produced(id, .plan(session.proposed)))
        }
        let receipt = AppliedConfirmation(interaction: id, conversation: session.conversation, planConversation: session.planConversation,
                                          suggester: suggester, offer: offer, until: resend.end(for: session.proposed, now: now()))
        applied[session.conversation] = receipt
        await store(.applied(receipt))
        close(id)
        await acknowledge(offer, to: suggester, in: session.conversation, planConversation: session.planConversation, interaction: id)
        startResending(id.rawValue)
        await dequeue(session.planConversation)
    }

    /// Ends a session that is settled without an ending (the change applies),
    /// keeping its conversation open for acknowledgments.
    private func close(_ id: InteractionID) {
        cancelSends(of: id)
        timers.removeValue(forKey: id)?.cancel()
        deadlines[id] = nil
        guard let session = sessions.removeValue(forKey: id) else { return }
        byConversation[session.conversation] = nil
        if openByPlan[session.planConversation] == id { openByPlan[session.planConversation] = nil }
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
        await finish(id, with: [session.role == .suggester ? .noAgreement : .expired])
    }

    /// Ends whatever is open for a plan (its people changed), quietly.
    private func settle(planConversation: ConversationID) async {
        guard let id = openByPlan[planConversation], let session = sessions[id] else { return }
        if session.role == .suggester {
            cancelSends(of: id)
            _ = await send(session.withdrawals, in: id)
        }
        queued[planConversation] = nil
        await finish(id, with: [.noAgreement])
    }

    // MARK: - Restart

    /// Open suggestions cannot be resumed (their offers' IDs are not
    /// stored): each is retired and reported failed, and the plan stays as
    /// it was. Ended ones are retired again, in case the app quit first.
    public func restore(_ interactions: [Interaction]) async {
        await retryRetirements()
        await recoverJournal()
        for interaction in interactions where interaction.skill.id == descriptor.id {
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

    private func store(_ record: ChangePlanRecord) async {
        do { try await journal.save(record) } catch { journalFailures += 1 }
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
            if delivery.pending[envelope.sender] == ack.proposal {
                delivery.pending[envelope.sender] = nil
                confirming[id] = delivery
                await progressDelivery(.confirming(delivery))
            }
            return true
        }
        for (id, var delivery) in leaving where delivery.pending[envelope.sender]?.contains(ack.proposal) == true {
            delivery.pending[envelope.sender] = nil
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
           confirmation.proposal == receipt.offer {
            await acknowledge(receipt.offer, to: receipt.suggester, in: receipt.conversation, planConversation: receipt.planConversation,
                              interaction: receipt.interaction)
        }
        return true
    }

    /// Saves a delivery's progress; one that everyone acknowledged is done.
    private func progressDelivery(_ record: ChangePlanRecord) async {
        switch record {
        case .confirming(let delivery) where delivery.pending.isEmpty: await endDelivery(record.key)
        case .leaving(let delivery) where delivery.pending.isEmpty: await endDelivery(record.key)
        default: await store(record)
        }
    }

    /// Each leave notice goes in a fresh conversation, under a fresh ID
    /// registered before the send (#105), so a friend can close it at once.
    private func sendLeaveNotices(_ id: InteractionID) async {
        guard let delivery = leaving[id] else { return }
        for peer in delivery.order where leaving[id]?.pending[peer] != nil {
            let notice = MessageID()
            leaving[id]?.pending[peer]?.append(notice)
            if let current = leaving[id] { await store(.leaving(current)) }
            _ = try? await outbox.send(.reject(Rejection(proposal: notice, reason: .declinedByOwner)), to: peer, conversation: ConversationID(),
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
        for byPeer in departed.values {
            if let departure = byPeer.values.first(where: { $0.id == key }) { return departure.until }
        }
        return nil
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
            for (plan, byPeer) in departed {
                guard let departure = byPeer.values.first(where: { $0.id == key }) else { continue }
                departed[plan]?[departure.peer] = nil
                if departed[plan]?.isEmpty == true { departed[plan] = nil }
                await forget(key)
            }
        }
        task?.cancel()
    }

    /// At launch: everything still owed or kept comes back, and resending
    /// picks up where it was (at once, then on the schedule).
    private func recoverJournal() async {
        let records: [ChangePlanRecord]
        do { records = try await journal.records() } catch {
            journalFailures += 1
            return
        }
        for record in records {
            switch record {
            case .confirming(let delivery):
                confirming[delivery.interaction] = delivery
                confirmingByConversation[delivery.conversation] = delivery.interaction
            case .applied(let receipt):
                applied[receipt.conversation] = receipt
            case .leaving(let delivery):
                leaving[delivery.interaction] = delivery
            case .departed(let departure):
                departed[departure.planConversation, default: [:]][departure.peer] = departure
            }
            if record.until <= now() {
                await endDelivery(record.key)
            } else {
                await resendOnce(record.key)
                startResending(record.key)
            }
        }
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

extension Terms {
    static let empty = try! Terms([:])
}
