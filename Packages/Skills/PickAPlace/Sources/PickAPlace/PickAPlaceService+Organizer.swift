import Foundation
import StarlingCore

// The organizer's side: ask, choose, propose, confirm (ADR 0230).

struct Organizer {
    enum Phase: Equatable { case asking, proposing, settled, ended }

    /// The step a send was made for (ADR 0011, amendment 14).
    enum Step: Equatable { case asking, proposing(UInt32) }

    let id: InteractionID
    let conversation: ConversationID
    let chainedFrom: ConversationID?
    /// Friends asked, in the order the request listed them.
    let friends: [PeerID]
    /// The organizer's acceptable candidates, best first: what friends are
    /// asked about.
    let ranking: [PlaceChoice]
    let base: Plan?
    let time: TimeSlot?
    let activity: Keyword?
    var phase: Phase = .asking
    /// Each friend's acceptable venues, best first.
    var answers: [PeerID: [PlaceChoice]] = [:]
    /// Friends who will not be in the plan: another major version, or a
    /// reply that was not a list.
    var out: Set<PeerID> = []
    var lastHeard: [PeerID: MessageID] = [:]
    /// Friends the policy refuses to send to (only on-device agents, or an
    /// unverified pairing). Nothing more is sent to them, and they count as
    /// silent, so the request runs exactly as if they had not answered:
    /// nobody can tell an exclusion from silence (ADR 0020).
    var excluded: Set<PeerID> = []
    var proposal: SkillProposal?
    var lastProposeID: [PeerID: MessageID] = [:]
    /// The queries sent to each friend, most recent last and bounded. A
    /// list counts only when it names one of them (issue #63).
    var queryIDs: [PeerID: [MessageID]] = [:]
    /// The proposals sent to each friend, most recent last and bounded. A
    /// yes counts only when it names one of them.
    var proposeIDs: [PeerID: [MessageID]] = [:]
    /// Queries and proposals on their way to each friend, one token per
    /// send attempt, with the step it was made for. Outbox returns a sent
    /// envelope only after its observer has run, which can be after the
    /// friend has already replied to it, and two sends to one friend can
    /// be returning at once (issue #105).
    var pending: [PeerID: [UUID: Step]] = [:]
    /// Replies that named an envelope this organizer has not recorded yet,
    /// while a send of the current step to their sender was pending; newest
    /// last and bounded. Each is judged again when such a send returns, and
    /// counts only if it names what was sent; it is dropped once no send it
    /// could name is pending.
    var early: [PeerID: [Envelope]] = [:]
    var accepted: Set<PeerID> = []
    /// Friends who passed or took their yes back. Final: a late or
    /// repeated yes from them is ignored, so a withdrawal is never undone.
    var passed: Set<PeerID> = []
    /// Friends who had not answered the proposal when the confirm deadline
    /// passed. Final, like a pass.
    var timedOut: Set<PeerID> = []
    /// When friends who have not answered the proposal are left out. An
    /// absolute time, so it holds whether or not the owner has tapped yet.
    var confirmDeadline: Date?
    /// When the request expires; kept in the ledger with the deadline.
    var expiresAt: Date?
    var ownerAccepted = false
    var finalTerms: Terms?
    var confirmationsRepeated: [PeerID: Int] = [:]

    var isFinished: Bool { phase == .settled || phase == .ended }
    var step: Step? {
        switch phase {
        case .asking: .asking
        case .proposing: proposal.map { .proposing($0.revision) }
        case .settled, .ended: nil
        }
    }
    var invited: [PeerID] { proposal?.participants.filter { friends.contains($0) } ?? [] }
    var waitingOn: [PeerID] { friends.filter { answers[$0] == nil && !out.contains($0) } }
    /// Friends who still think something may happen.
    var stillInvolved: [PeerID] {
        switch phase {
        case .asking: friends.filter { !out.contains($0) && !excluded.contains($0) }
        case .proposing: invited.filter { !passed.contains($0) && !timedOut.contains($0) && !excluded.contains($0) }
        case .settled, .ended: []
        }
    }
}

extension PickAPlaceService {
    public func start(_ request: SkillRequest) async throws {
        let ref = request.intent.skill
        guard ref.id == descriptor.id, ref.version.isCompatible(with: descriptor.ref.version) else { throw PickAPlaceError.wrongSkill }
        guard isNew(request) else { throw PickAPlaceError.alreadyStarted }

        let candidates = try await candidateSource.candidates(for: request)
        guard !candidates.isEmpty else { throw PickAPlaceError.noCandidates }
        // Ask only about places the owner can do: the owner's own limits are
        // applied before anything leaves, and never sent.
        let ranking = PickAPlaceSkill.askable(candidates, limits: request.intent.rules.constraints)
        guard !ranking.isEmpty else { throw PickAPlaceError.nothingFitsYourLimits }
        guard isNew(request) else { throw PickAPlaceError.alreadyStarted }

        // Friends whose card says they cannot run this skill are left out
        // before anything is sent; a friend with no card yet is asked, and
        // an older version answers `unsupported`.
        var unique: Set<PeerID> = [localPeer]
        let friends = request.participants
            .filter { unique.insert($0).inserted }
            .filter { cards[$0]?.support(for: descriptor.ref).isSupported ?? true }
            .prefix(ProtocolLimits.maxAttendees - 1)

        var base: Plan?
        var time: TimeSlot?
        for input in request.inputs {
            switch input {
            case .plan(let plan): base = base ?? plan
            case .timeSlot(let slot): time = time ?? slot
            case .placeChoice, .attendees: break
            }
        }

        let conversation = request.conversation
        conversationOf[request.interaction] = conversation
        organized[conversation] = Organizer(
            id: request.interaction, conversation: conversation, chainedFrom: request.chainedFrom,
            friends: Array(friends), ranking: ranking, base: base, time: base?.time ?? time, activity: base?.activity
        )
        guard !friends.isEmpty else {
            organized[conversation]?.phase = .ended
            rememberOrganizer(conversation)
            // Negotiating, so the state machine ends it as unsupported.
            finish(conversation, interaction: request.interaction, event: .unsupported)
            return
        }
        // The request's expiry is in the ledger before anything is sent, so
        // a relaunch keeps it (re-review of PR #55, finding 2).
        let expiry = request.intent.expiresAt.date
        organized[conversation]?.expiresAt = expiry
        do {
            try await ledger.recordDeadlines(RequestDeadlines(expiresAt: expiry), for: conversation)
        } catch {
            organized[conversation] = nil
            conversationOf[request.interaction] = nil
            throw PickAPlaceError.ledgerUnavailable
        }
        // The coordinator applied `.started` before calling `start` (ADR
        // 0011, amendment 13); the service never reports it.
        for friend in friends {
            spawn(conversation, asking: true) { await $0.keepAsking(conversation, friend) }
        }
        let window = configuration.answerWindow
        spawn(conversation) { service in
            guard (try? await service.clock.sleep(window)) != nil, !Task.isCancelled else { return }
            service.decide(conversation)
        }
        spawnExpiry(conversation, at: expiry)
    }

    func spawnExpiry(_ conversation: ConversationID, at expiry: Date) {
        spawn(conversation) { service in
            guard await service.sleep(until: expiry) else { return }
            service.endOrganizer(conversation, event: .expired, reason: .expired)
        }
    }

    /// When the owner's own chance to confirm runs out: one confirm window
    /// after the deadline, or at the request's expiry, whichever is first.
    func ownerDeadline(of organizer: Organizer) -> Date? {
        let confirm = organizer.confirmDeadline.map { $0.addingTimeInterval(Self.seconds(configuration.confirmWindow)) }
        return [confirm, organizer.expiresAt].compactMap { $0 }.min()
    }

    private func isNew(_ request: SkillRequest) -> Bool {
        conversationOf[request.interaction] == nil && organized[request.conversation] == nil && invites[request.conversation] == nil
    }

    // MARK: - Asking

    func keepAsking(_ conversation: ConversationID, _ friend: PeerID) async {
        var interval = configuration.retryInterval
        while let organizer = organized[conversation], organizer.phase == .asking, organizer.waitingOn.contains(friend),
              !organizer.excluded.contains(friend) {
            let token = sendStarting(conversation, to: friend, step: .asking)
            do {
                let query = try Query(issue: .place, candidates: .places(organizer.ranking))
                let sent = try await send(.query(query), to: friend, conversation: conversation, chainedFrom: organizer.chainedFrom)
                if sendEnded(conversation, to: friend, token: token) {
                    organized[conversation]?.queryIDs[friend, default: []].append(sent.id)
                    if let count = organized[conversation]?.queryIDs[friend]?.count, count > Self.maxRememberedProposals {
                        organized[conversation]?.queryIDs[friend]?.removeFirst(count - Self.maxRememberedProposals)
                    }
                    judgeHeld(conversation, from: friend)
                }
            } catch {
                if sendEnded(conversation, to: friend, token: token) { judgeHeld(conversation, from: friend) }
                guard organizerCanRetry(conversation, after: error, step: .asking, friend: friend) else { return }
            }
            guard let next = await pause(interval) else { return }
            interval = next
        }
    }

    func organizerReceived(_ envelope: Envelope) {
        let conversation = envelope.conversation
        let sender = envelope.sender
        guard var organizer = organized[conversation], organizer.friends.contains(sender) else { return }
        organizer.lastHeard[sender] = envelope.id

        switch (organizer.phase, envelope.body) {
        case (.asking, .answer(let answer)):
            // Only an answer to a query this organizer sent that friend, in
            // this conversation and step, counts (issue #63).
            guard organizer.waitingOn.contains(sender), answer.issue == .place else { return }
            guard organizer.queryIDs[sender]?.contains(answer.query) == true else {
                holdIfEarly(envelope, in: &organizer)
                return
            }
            switch answer.status {
            case .answered:
                guard case .places(let list)? = answer.acceptable else { organizer.out.insert(sender); break }
                // Only places that were asked about count, once each, in the
                // friend's order.
                var seen: Set<PlaceChoice> = []
                organizer.answers[sender] = list.filter { organizer.ranking.contains($0) && seen.insert($0).inserted }
            case .declined:
                organizer.out.insert(sender)
            case .pendingOwner:
                break
            }
        case (.asking, .reject):
            organizer.out.insert(sender)
        case (.proposing, .accept(let acceptance)):
            guard organizer.invited.contains(sender), !organizer.passed.contains(sender), !organizer.timedOut.contains(sender),
                  acceptance.terms == organizer.proposal?.terms
            else { return }
            guard organizer.proposeIDs[sender]?.contains(acceptance.proposal) == true else {
                holdIfEarly(envelope, in: &organizer)
                return
            }
            organizer.accepted.insert(sender)
        case (.proposing, .reject):
            guard organizer.invited.contains(sender) else { return }
            organizer.accepted.remove(sender)
            organizer.passed.insert(sender)
            acknowledge(envelope)
        case (.settled, .reject):
            acknowledge(envelope)
            // A withdrawal that crossed the confirmation wins: the friend's
            // phone has already ended, so the plan goes on without them.
            guard organizer.accepted.contains(sender) else { return }
            organized[conversation] = organizer
            withdrawAfterConfirmation(sender, in: conversation)
            return
        case (.ended, _):
            // Retired: nothing more is sent here (ADR 0021).
            return
        case (.settled, .accept(let acceptance)):
            // A friend who said yes did not hear the confirmation: repeat
            // it, a bounded number of times.
            let repeats = organizer.confirmationsRepeated[sender, default: 0]
            if organizer.accepted.contains(sender), acceptance.terms == organizer.proposal?.terms, repeats < configuration.maxConfirmationRepeats {
                organizer.confirmationsRepeated[sender] = repeats + 1
                spawnConfirmation(conversation, to: sender, organizer: organizer)
            }
        default:
            return
        }
        organized[conversation] = organizer

        switch organizer.phase {
        case .asking where organizer.waitingOn.isEmpty: decide(conversation)
        case .proposing: tryFinalize(conversation)
        default: break
        }
    }

    // MARK: - Choosing and proposing

    /// Chooses the group's place from the lists so far and proposes it.
    func decide(_ conversation: ConversationID) {
        guard var organizer = organized[conversation], organizer.phase == .asking else { return }
        guard let choice = GroupChoice.choose(organizer: organizer.ranking, answers: organizer.answers.filter { !$0.value.isEmpty }) else {
            endOrganizer(conversation, event: .noAgreement, reason: .noOverlap)
            return
        }
        let left = organizer.friends.filter { !choice.friends.contains($0) && !organizer.out.contains($0) && !organizer.excluded.contains($0) }
        // The organizer comes first in the roster, so a friend's phone can
        // tell who organized it after a restart.
        let roster = [localPeer] + choice.friends
        var values: [IssueKey: IssueValue] = [.place: .places([choice.place]), .people: .peers(roster)]
        if let time = organizer.time { values[.time] = .slots([time]) }
        if let activity = organizer.activity { values[.activity] = .keywords([activity]) }
        let terms = try! Terms(values)
        let revision = (organizer.proposal?.revision ?? 0) + 1
        let plan = Self.plan(base: organizer.base, origin: organizer.chainedFrom ?? conversation, roster: roster, terms: terms, place: choice.place)
        let proposal = SkillProposal(revision: revision, participants: roster, terms: terms, plan: plan)
        organizer.proposal = proposal
        organizer.phase = .proposing
        // Queries still returning, and replies held for them, belong to a
        // step that is over.
        organizer.pending = [:]
        organizer.early = [:]
        organizer.out.formUnion(left)
        organizer.out.formUnion(organizer.excluded)
        organized[conversation] = organizer
        // A query still waiting on a consent sheet must not reach a friend
        // who has already been told "no plan".
        cancelAsking(conversation)

        // Friends the place does not fit, and friends who never answered,
        // hear "no plan" and nothing else.
        let chainedFrom = organizer.chainedFrom
        for friend in left {
            let lastHeard = organizer.lastHeard[friend]
            spawn(conversation) { service in
                await service.trySend(.reject(Rejection(proposal: lastHeard ?? MessageID(), reason: .noOverlap)), to: friend,
                                      conversation: conversation, chainedFrom: chainedFrom)
            }
        }
        // The confirm deadline is fixed now and kept in the ledger before
        // the proposal goes out, so a relaunch keeps it.
        let deadline = clock.now().addingTimeInterval(Self.seconds(configuration.confirmWindow))
        organized[conversation]?.confirmDeadline = deadline
        let record = organizer.expiresAt.map { RequestDeadlines(expiresAt: $0, confirmDeadline: deadline) }
        let id = organizer.id
        spawn(conversation) { service in
            if let record { try? await service.ledger.recordDeadlines(record, for: conversation) }
            guard service.organized[conversation]?.phase == .proposing else { return }
            service.emit(id, .proposalReady(proposal))
            service.startProposing(conversation)
        }
    }

    func startProposing(_ conversation: ConversationID) {
        guard var organizer = organized[conversation] else { return }
        let deadline = organizer.confirmDeadline ?? clock.now().addingTimeInterval(Self.seconds(configuration.confirmWindow))
        organizer.confirmDeadline = deadline
        organized[conversation] = organizer
        for friend in organizer.invited {
            spawn(conversation) { await $0.keepProposing(conversation, friend) }
        }
        spawn(conversation) { service in
            guard await service.sleep(until: deadline) else { return }
            service.confirmWindowClosed(conversation)
        }
        // The owner gets one more confirm window after the deadline. A
        // request still unconfirmed then is over, and everyone hears so, so
        // a friend's phone never keeps waiting on a yes that is not coming.
        if let cutoff = ownerDeadline(of: organizer) {
            spawn(conversation) { service in
                guard await service.sleep(until: cutoff) else { return }
                service.endOrganizer(conversation, event: .expired, reason: .expired)
            }
        }
    }

    func keepProposing(_ conversation: ConversationID, _ friend: PeerID) async {
        var interval = configuration.retryInterval
        while let organizer = organized[conversation], organizer.phase == .proposing, let proposal = organizer.proposal,
              organizer.invited.contains(friend), !organizer.accepted.contains(friend), !organizer.passed.contains(friend),
              !organizer.timedOut.contains(friend), !organizer.excluded.contains(friend) {
            let token = sendStarting(conversation, to: friend, step: .proposing(proposal.revision))
            do {
                let round = UInt16(min(proposal.revision - 1, UInt32(ProtocolLimits.maxNegotiationRounds - 1)))
                let sent = try await send(.propose(Proposal(round: round, terms: proposal.terms)), to: friend,
                                          conversation: conversation, chainedFrom: organizer.chainedFrom)
                if sendEnded(conversation, to: friend, token: token) {
                    organized[conversation]?.lastProposeID[friend] = sent.id
                    organized[conversation]?.proposeIDs[friend, default: []].append(sent.id)
                    if let count = organized[conversation]?.proposeIDs[friend]?.count, count > Self.maxRememberedProposals {
                        organized[conversation]?.proposeIDs[friend]?.removeFirst(count - Self.maxRememberedProposals)
                    }
                    judgeHeld(conversation, from: friend)
                }
            } catch {
                if sendEnded(conversation, to: friend, token: token) { judgeHeld(conversation, from: friend) }
                guard organizerCanRetry(conversation, after: error, step: .proposing(proposal.revision), friend: friend) else { return }
            }
            guard let next = await pause(interval) else { return }
            interval = next
        }
    }

    /// Proposals remembered per friend, so a yes naming one sent a while ago
    /// still counts.
    static let maxRememberedProposals = 32

    /// Replies held per friend while a send to them has not returned.
    static let maxEarlyReplies = 4

    /// Notes a query or proposal to `friend` before it is sent, so a reply
    /// that arrives before the send returns can be held for it.
    func sendStarting(_ conversation: ConversationID, to friend: PeerID, step: Organizer.Step) -> UUID {
        let token = UUID()
        organized[conversation]?.pending[friend, default: [:]][token] = step
        return token
    }

    /// Ends the send `token` names. True if it is still pending: its step
    /// has not ended since, so it may record what it sent. A stale send
    /// records nothing and judges nothing.
    func sendEnded(_ conversation: ConversationID, to friend: PeerID, token: UUID) -> Bool {
        guard organized[conversation]?.pending[friend]?.removeValue(forKey: token) != nil else { return false }
        if organized[conversation]?.pending[friend]?.isEmpty == true { organized[conversation]?.pending[friend] = nil }
        return true
    }

    /// After a send to `friend` returned, sent or not: a held reply that now
    /// names something recorded is handled; one that could still name a
    /// send of the current step that is pending stays held; the rest are
    /// dropped, as they would have been on arrival (issue #63).
    func judgeHeld(_ conversation: ConversationID, from friend: PeerID) {
        guard let organizer = organized[conversation], let held = organizer.early[friend] else { return }
        var ready: [Envelope] = []
        var waiting: [Envelope] = []
        for envelope in held {
            if Self.namesRecorded(envelope, in: organizer) {
                ready.append(envelope)
            } else if Self.mayNamePending(envelope, in: organizer) {
                waiting.append(envelope)
            }
        }
        organized[conversation]?.early[friend] = waiting.isEmpty ? nil : waiting
        for envelope in ready { organizerReceived(envelope) }
    }

    /// Whether a reply names a query or proposal recorded as sent to its
    /// sender.
    static func namesRecorded(_ envelope: Envelope, in organizer: Organizer) -> Bool {
        switch envelope.body {
        case .answer(let answer): organizer.queryIDs[envelope.sender]?.contains(answer.query) == true
        case .accept(let acceptance): organizer.proposeIDs[envelope.sender]?.contains(acceptance.proposal) == true
        default: false
        }
    }

    /// Whether a reply is the kind the current step expects, and a send of
    /// that step to its sender has not returned yet.
    static func mayNamePending(_ envelope: Envelope, in organizer: Organizer) -> Bool {
        guard let step = organizer.step else { return false }
        switch (envelope.body, step) {
        case (.answer, .asking), (.accept, .proposing): break
        default: return false
        }
        return organizer.pending[envelope.sender]?.values.contains(step) == true
    }

    /// Holds a reply that names an envelope not recorded yet, if a send of
    /// the current step to its sender may still be returning. Otherwise it
    /// is dropped.
    func holdIfEarly(_ envelope: Envelope, in organizer: inout Organizer) {
        let sender = envelope.sender
        guard Self.mayNamePending(envelope, in: organizer) else { return }
        var held = organizer.early[sender, default: []]
        held.append(envelope)
        if held.count > Self.maxEarlyReplies { held.removeFirst(held.count - Self.maxEarlyReplies) }
        organizer.early[sender] = held
        organized[envelope.conversation] = organizer
    }

    func organizerAnswer(_ conversation: ConversationID, _ answer: OwnerAnswer) async throws {
        guard let organizer = organized[conversation], organizer.phase == .proposing, let proposal = organizer.proposal else {
            throw PickAPlaceError.notWaitingForYou
        }
        // A tap after the owner's own deadline does not count: the request
        // is over.
        if let cutoff = ownerDeadline(of: organizer), clock.now() >= cutoff {
            endOrganizer(conversation, event: .expired, reason: .expired)
            throw PickAPlaceError.notWaitingForYou
        }
        switch answer {
        case .accept(let revision):
            guard revision == proposal.revision else { throw PickAPlaceError.staleProposal }
            guard !organizer.ownerAccepted else { return }
            organized[conversation]?.ownerAccepted = true
            emit(organizer.id, .ownerAccepted(revision: revision))
            tryFinalize(conversation)
        case .pass:
            // After a yes, passing takes the yes back: withdrawing.
            endOrganizer(conversation, event: organizer.ownerAccepted ? .withdrawn : .ownerPassed, reason: .noOverlap)
        case .reply:
            throw PickAPlaceError.notWaitingForYou
        }
    }

    // MARK: - Confirming

    func tryFinalize(_ conversation: ConversationID) {
        guard let organizer = organized[conversation], organizer.phase == .proposing, organizer.ownerAccepted else { return }
        // Only yeses settle a friend early. A pass, like silence, waits for
        // the confirm deadline, so nobody can tell the two apart by when the
        // plan is confirmed (ADR 0017; ADR 0020, decision 9).
        guard organizer.invited.allSatisfy({ organizer.accepted.contains($0) || organizer.timedOut.contains($0) }) else { return }
        finalize(conversation)
    }

    /// The confirm deadline: friends who have not answered are left out now
    /// and hear the request expired, whether or not the owner has tapped.
    /// The owner's yes, now or later, confirms with whoever said yes.
    func confirmWindowClosed(_ conversation: ConversationID) {
        guard var organizer = organized[conversation], organizer.phase == .proposing else { return }
        let unsettled = organizer.invited.filter { !organizer.accepted.contains($0) && !organizer.timedOut.contains($0) }
        organizer.timedOut.formUnion(unsettled)
        organized[conversation] = organizer
        let chainedFrom = organizer.chainedFrom
        // Those still waiting hear the request expired; a friend who passed
        // or was excluded hears nothing more.
        for friend in unsettled where !organizer.excluded.contains(friend) && !organizer.passed.contains(friend) {
            let lastHeard = organizer.lastHeard[friend]
            spawn(conversation) { service in
                await service.trySend(.reject(Rejection(proposal: lastHeard ?? MessageID(), reason: .expired)), to: friend,
                                      conversation: conversation, chainedFrom: chainedFrom)
            }
        }
        tryFinalize(conversation)
    }

    /// Confirms the place with everyone who said yes.
    func finalize(_ conversation: ConversationID) {
        guard var organizer = organized[conversation], organizer.phase == .proposing, let proposal = organizer.proposal,
              case .places(let places)? = proposal.terms[.place], let place = places.first
        else { return }
        let yes = organizer.invited.filter(organizer.accepted.contains)
        let silent = organizer.invited.filter {
            !organizer.accepted.contains($0) && !organizer.passed.contains($0) && !organizer.timedOut.contains($0)
                && !organizer.excluded.contains($0)
        }
        guard !yes.isEmpty else {
            endOrganizer(conversation, event: .noAgreement, reason: .noOverlap)
            return
        }
        var values = proposal.terms.values
        values[.people] = .peers([localPeer] + yes)
        organizer.finalTerms = try! Terms(values)
        organizer.phase = .settled
        organizer.pending = [:]
        organizer.early = [:]
        organized[conversation] = organizer
        cancelTasks(conversation)
        rememberOrganizer(conversation)

        for friend in yes { spawnConfirmation(conversation, to: friend, organizer: organizer) }
        let chainedFrom = organizer.chainedFrom
        for friend in silent {
            let lastHeard = organizer.lastHeard[friend]
            spawn(conversation) { service in
                await service.trySend(.reject(Rejection(proposal: lastHeard ?? MessageID(), reason: .expired)), to: friend,
                                      conversation: conversation, chainedFrom: chainedFrom)
            }
        }
        emit(organizer.id, .everyoneConfirmed(revision: proposal.revision))
        continuation.yield(.produced(organizer.id, .placeChoice(place)))
        // The proposal's roster may name friends who passed or never
        // answered; these are the people actually in the plan.
        if let attendees = try? Attendees([localPeer] + yes) {
            continuation.yield(.produced(organizer.id, .attendees(attendees)))
        }
    }

    /// The owner withdraws a confirmed plan. Confirmations still on their
    /// way, held by the policy or a consent sheet, are cancelled and no
    /// more are sent; everyone in the final roster hears the ordinary no
    /// (final review of PR #55, finding 2).
    func callOff(_ conversation: ConversationID) {
        guard var organizer = organized[conversation], organizer.phase == .settled else { return }
        let roster: [PeerID] = if case .peers(let people)? = organizer.finalTerms?[.people] { people } else { organizer.invited }
        organizer.phase = .ended
        organized[conversation] = organizer
        cancelTasks(conversation)
        let goodbyes: [(PeerID, MessageBody)] = roster.filter { $0 != localPeer }.map {
            ($0, .reject(Rejection(proposal: organizer.lastHeard[$0] ?? MessageID(), reason: .noOverlap)))
        }
        finish(conversation, interaction: organizer.id, event: .withdrawn, goodbyes: goodbyes, chainedFrom: organizer.chainedFrom)
    }

    /// Takes a friend out of a confirmed plan: everyone left gets the
    /// shortened roster, as a confirmation, and the plan's attendees update.
    func withdrawAfterConfirmation(_ friend: PeerID, in conversation: ConversationID) {
        guard var organizer = organized[conversation], organizer.phase == .settled, let terms = organizer.finalTerms,
              case .peers(let roster)? = terms[.people]
        else { return }
        organizer.accepted.remove(friend)
        organizer.passed.insert(friend)
        let remaining = roster.filter { $0 != friend }
        guard remaining.count >= 2, let attendees = try? Attendees(remaining) else {
            // Nobody else is left to meet.
            organizer.phase = .ended
            organized[conversation] = organizer
            finish(conversation, interaction: organizer.id, event: .failed)
            return
        }
        var values = terms.values
        values[.people] = .peers(remaining)
        organizer.finalTerms = try? Terms(values)
        organizer.confirmationsRepeated = [:]
        organized[conversation] = organizer
        for other in remaining where other != localPeer { spawnConfirmation(conversation, to: other, organizer: organizer) }
        continuation.yield(.produced(organizer.id, .attendees(attendees)))
    }

    func spawnConfirmation(_ conversation: ConversationID, to friend: PeerID, organizer: Organizer) {
        guard let terms = organizer.finalTerms else { return }
        let acceptance = Acceptance(proposal: organizer.lastProposeID[friend] ?? MessageID(), terms: terms)
        spawn(conversation) { service in
            await service.trySend(.accept(acceptance), to: friend, conversation: conversation, chainedFrom: organizer.chainedFrom)
        }
    }

    // MARK: - Ending

    /// Ends the request: friends still involved hear `reason` and nothing
    /// else, and the coordinator gets `event`, if any.
    func endOrganizer(_ conversation: ConversationID, event: InteractionEvent?, reason: Rejection.Reason) {
        guard var organizer = organized[conversation], !organizer.isFinished else { return }
        let tell = organizer.stillInvolved
        organizer.phase = .ended
        organizer.pending = [:]
        organizer.early = [:]
        organized[conversation] = organizer
        cancelTasks(conversation)
        rememberOrganizer(conversation)
        let goodbyes: [(PeerID, MessageBody)] = tell.map {
            ($0, .reject(Rejection(proposal: organizer.lastHeard[$0] ?? MessageID(), reason: reason)))
        }
        finish(conversation, interaction: organizer.id, event: event, goodbyes: goodbyes, chainedFrom: organizer.chainedFrom)
    }

    /// Keeps a bounded number of finished requests, so late messages are
    /// still recognized for a while.
    func rememberOrganizer(_ conversation: ConversationID) {
        endedOrganizers.append(conversation)
        while endedOrganizers.count > configuration.maxRememberedRequests {
            let oldest = endedOrganizers.removeFirst()
            if let organizer = organized.removeValue(forKey: oldest) { conversationOf[organizer.id] = nil }
            cancelTasks(oldest)
        }
    }

    /// What a failed send means for the whole request. Returns whether to
    /// keep retrying. A send made for a step the request has left is
    /// dropped, whatever its result (ADR 0011, amendment 14).
    func organizerCanRetry(_ conversation: ConversationID, after error: any Error, step: Organizer.Step, friend: PeerID) -> Bool {
        guard var organizer = organized[conversation], !organizer.isFinished, organizer.step == step else { return false }
        switch error {
        case OutboxError.denied(let violation) where violation.issue == nil:
            // A rule about this recipient, not a topic: only on-device
            // agents and this friend's card says otherwise, or the paired
            // store could not vouch for them. Leave this friend out the way
            // silence would: no early decision, no early confirmation, and
            // nothing more sent to them.
            organizer.excluded.insert(friend)
            organizer.accepted.remove(friend)
            organized[conversation] = organizer
            return false
        case OutboxError.denied:
            // A topic set to Never, at any live step.
            endOrganizer(conversation, event: .blockedByPrivacy, reason: .noOverlap)
            return false
        case OutboxError.consentDeclined:
            // Passing on the consent sheet passes on the request; the
            // coordinator applies the pass, so the service adds nothing.
            endOrganizer(conversation, event: nil, reason: .noOverlap)
            return false
        case is CancellationError:
            return false
        default:
            // Unreachable for now, or the policy changed while the sheet was
            // up: try again later.
            return true
        }
    }
}
