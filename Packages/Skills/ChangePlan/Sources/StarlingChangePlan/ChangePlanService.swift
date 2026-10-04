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

    /// At most this many suggestions wait behind an open one, per plan.
    static let maxQueued = 4

    /// - Parameters:
    ///   - ledger: the app's `ConversationLedger`, the one its Outbox uses.
    ///   - planLookup: the standing plan a conversation names on this phone
    ///     (by `Plan.origin`), with the interaction that holds it.
    ///   - sleep: waits until a date; a suggestion's window closes then.
    public init(outbox: Outbox, ledger: any ConversationLedger, me: PeerID, planLookup: @escaping @Sendable (ConversationID) async -> PlanRef?,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Date) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow))) }) {
        self.outbox = outbox
        self.ledger = ledger
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
    /// disclosed but that the owner left.
    private func leave(_ request: SkillRequest, plan: PlanRef, others: [PeerID]) async {
        sessions[request.interaction] = Session(
            role: .suggester, conversation: request.conversation, planConversation: plan.plan.origin, planInteraction: plan.interaction,
            basisRevision: plan.plan.revision, proposed: plan.plan, suggester: nil, voters: others, friend: nil, terms: Terms.empty,
            inviteTerms: nil, step: .asking
        )
        byConversation[request.conversation] = request.interaction
        // The notice names no offer; a fresh ID stands in.
        _ = await send(others.map { (MessageBody.reject(Rejection(proposal: MessageID(), reason: .declinedByOwner)), $0) }, in: request.interaction,
                       failureEnds: false)
        await settle(planConversation: plan.plan.origin)
        await retire(plan.plan.origin)
        await finish(request.interaction, with: [.withdrawn], then: [.lifecycle(plan.interaction, .withdrawn)])
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
        guard case .message(let envelope) = event, let skill = envelope.skill, skill.id == descriptor.id,
              skill.version.isCompatible(with: descriptor.ref.version), envelope.recipient == me,
              let mode = envelope.mode, descriptor.sendModes.contains(mode), !closed.contains(envelope.conversation),
              let planConversation = envelope.chainedFrom
        else { return }
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

    /// Someone left the plan: a notice in a fresh conversation.
    private func left(_ envelope: Envelope, planConversation: ConversationID) async {
        guard let current = await planLookup(planConversation), current.plan.origin == planConversation,
              current.plan.attendees.peers.contains(envelope.sender), envelope.sender != me,
              byConversation[envelope.conversation] == nil, !closed.contains(envelope.conversation)
        else { return }
        // Anything open for this plan included them: it cannot go through.
        await settle(planConversation: planConversation)
        let id = InteractionID()
        let remaining = current.plan.attendees.peers.filter { $0 != envelope.sender }
        guard await retire(envelope.conversation) else { return }
        continuation.yield(.incoming(id, conversation: envelope.conversation, from: envelope.sender, chainedFrom: planConversation))
        emit(id, .withdrawn)
        if remaining.count >= 2, let attendees = try? Attendees(remaining), let smaller = try? current.plan.updating(attendees: attendees) {
            continuation.yield(.produced(current.interaction, .plan(smaller)))
        } else {
            // Only this phone is left: the plan ends here too.
            await retire(planConversation)
            emit(current.interaction, .withdrawn)
        }
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
            await applied(id)
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

    /// Everyone said yes: confirm to each, then apply here.
    private func confirm(_ id: InteractionID) async {
        guard let session = sessions[id] else { return }
        let confirmations = session.asked.compactMap { peer in
            session.offers[peer].map { (MessageBody.accept(Acceptance(proposal: $0, terms: Terms.empty)), peer) }
        }
        _ = await send(confirmations, in: id, failureEnds: false)
        var extra: [SkillEvent] = []
        if let plan = session.planInteraction { extra.append(.produced(plan, .plan(session.proposed))) }
        await finish(id, with: [.everyoneConfirmed(revision: 1)], then: extra)
    }

    /// A voter or joiner got the confirmation: the change applies here.
    private func applied(_ id: InteractionID) async {
        guard let session = sessions[id] else { return }
        if let planInteraction = session.planInteraction {
            // The plan must still be the one the suggestion changed.
            guard let current = await planLookup(session.planConversation), current.plan.revision == session.basisRevision else {
                await finish(id, with: [.noAgreement])
                return
            }
            await finish(id, with: [.everyoneConfirmed(revision: 1)], then: [.produced(planInteraction, .plan(session.proposed))])
        } else {
            // A friend being added: this interaction now holds the plan.
            await finish(id, with: [.everyoneConfirmed(revision: 1)], then: [.produced(id, .plan(session.proposed))])
        }
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
        inFlight = [:]
        timers = [:]
        continuation.finish()
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
                let envelope = try await outbox.send(body, to: peer, conversation: session.conversation,
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
