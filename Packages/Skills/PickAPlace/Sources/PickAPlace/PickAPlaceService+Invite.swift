import Foundation
import StarlingCore

// A friend's side: judge privately, answer with what fits, confirm
// (ADR 0230). Nothing here starts a skill, asks for a permission, or skips
// Consent: a request creates at most an invitee interaction (rule 8).

struct Invite {
    let id: InteractionID
    let conversation: ConversationID
    let organizer: PeerID
    let chainedFrom: ConversationID?
    /// The candidates of the first query. A conversation answers about one
    /// set only, so a friend learns yes or no about at most
    /// `ProtocolLimits.maxCandidatesAnsweredPerIssue` of them (ADR 0019,
    /// decision 6). Empty only for a request restored before its list was
    /// sent; the next query sets it.
    var candidates: [PlaceChoice]
    /// Whether the coordinator has heard of this request. A request where
    /// nothing fits is never announced.
    var announced = false
    /// The acceptable candidates, best first, once judged.
    var acceptable: [PlaceChoice]?
    var facts: [PlaceChoice: PlaceFacts] = [:]
    var answering = false
    var lastQuery: MessageID?
    var revision: UInt32 = 0
    var proposal: SkillProposal?
    var proposeID: MessageID?
    /// The proposal as the organizer offered it, for the policy to see that
    /// a yes repeats only its terms (ADR 0019, amendment 10).
    var offer: Proposal?
    var accepted = false
    /// The roster the organizer confirmed; it can only shrink afterwards.
    var finalRoster: [PeerID]?
    /// The owner's yes is on its way, possibly waiting on a consent sheet.
    var accepting = false
    /// Rises with each proposal that differs from the current card, when it
    /// arrives and before any await, so an older proposal whose checks
    /// resume late can never replace a newer one.
    var proposalGeneration: UInt64 = 0
    var finished = false

    var isFinished: Bool { finished }
}

extension PickAPlaceService {
    /// A query from a friend for a conversation this phone has not seen.
    func newInvite(_ envelope: Envelope) {
        guard case .query(let query) = envelope.body, query.issue == .place, case .places(let candidates) = query.candidates,
              candidates.count <= ProtocolLimits.maxCandidatesAnsweredPerIssue
        else { return }
        let live = invites.values.filter { !$0.isFinished }
        guard live.count < configuration.maxLiveRequests,
              live.filter({ $0.organizer == envelope.sender }).count < configuration.maxLiveRequestsPerFriend
        else { return }
        let hourAgo = clock.now().addingTimeInterval(-3_600)
        let recent = (requestTimes[envelope.sender] ?? []).filter { $0 > hourAgo }
        guard recent.count < configuration.maxNewRequestsPerFriendPerHour else {
            requestTimes[envelope.sender] = recent
            return
        }
        let now = clock.now()
        requestTimes[envelope.sender] = recent + [now]
        let conversation = envelope.conversation
        let sender = envelope.sender
        invites[conversation] = Invite(id: InteractionID(), conversation: conversation, organizer: envelope.sender,
                                       chainedFrom: envelope.chainedFrom, candidates: candidates)
        spawnInviteDeadline(conversation)
        spawn(conversation) { try? await $0.ledger.recordAdmission(sender, at: now) }
        spawn(conversation) { await $0.judgeAndAnswer(conversation, queryID: envelope.id, query: query) }
    }

    /// Ends a request the organizer stops answering. An honest organizer
    /// settles it within its answer window, a confirm window for friends,
    /// and one more for its own owner, so a request still open after a
    /// further confirm window is over. Without this, a silent or crashed
    /// organizer would hold a live slot, and Home's row, forever. A friend
    /// who said yes waits this long too, so it never gives up on a plan
    /// the organizer can still confirm.
    func spawnInviteDeadline(_ conversation: ConversationID) {
        let limit = configuration.answerWindow + configuration.confirmWindow * 3
        spawn(conversation) { service in
            guard (try? await service.clock.sleep(limit)) != nil, !Task.isCancelled else { return }
            service.endInvite(conversation, event: .expired, reply: nil)
        }
    }

    func inviteReceived(_ envelope: Envelope) {
        let conversation = envelope.conversation
        guard let invite = invites[conversation], envelope.sender == invite.organizer else { return }
        if invite.isFinished {
            guard invite.finalRoster != nil else { return }
            switch envelope.body {
            // After the plan is confirmed, only a shorter roster can follow:
            // someone took their yes back after the confirmation.
            case .accept(let acceptance): rosterShrank(acceptance, in: conversation)
            // The organizer called the plan off.
            case .reject: planCalledOff(conversation)
            default: break
            }
            return
        }
        switch envelope.body {
        case .query(let query):
            // Once a proposal is on the card, the list has done its job: no
            // query is answered again, so a friend who passed and one who
            // has not decided look the same (final review of PR #55).
            guard invite.proposal == nil else { return }
            // A retry asks about the same candidates; any other set is not
            // answered (ADR 0019, decision 6).
            guard query.issue == .place, case .places(let candidates) = query.candidates,
                  candidates.count <= ProtocolLimits.maxCandidatesAnsweredPerIssue
            else { return }
            if invite.candidates.isEmpty { invites[conversation]?.candidates = candidates }
            guard Set(candidates) == Set(invites[conversation]?.candidates ?? []) else { return }
            spawn(conversation) { await $0.judgeAndAnswer(conversation, queryID: envelope.id, query: query) }
        case .propose(let proposal):
            if let current = invite.proposal, current.terms == proposal.terms {
                // A retry. If the owner already said yes, say it again.
                invites[conversation]?.proposeID = envelope.id
                if invite.accepted { spawnAcceptance(conversation) }
                return
            }
            invites[conversation]?.proposalGeneration += 1
            let generation = invite.proposalGeneration + 1
            spawn(conversation) { await $0.received(proposal, id: envelope.id, in: conversation, generation: generation) }
        case .accept(let acceptance):
            confirmed(acceptance, in: conversation)
        case .reject(let rejection):
            endInvite(conversation, event: rejection.reason == .expired ? .expired : .noAgreement, reply: nil)
        default:
            return
        }
    }

    // MARK: - Judging privately

    /// Judges the candidates against the owner's limits with facts this
    /// phone looks up, then answers with the ones that fit, as a yes or no
    /// to the friend's own options (ADR 0019, decision 4). A retry of the
    /// same query gets the same list. When nothing fits, the friend gets an
    /// ordinary no (`noOverlap`) and the owner sees nothing: a limit set to
    /// Never looks like any other no (decision 5).
    func judgeAndAnswer(_ conversation: ConversationID, queryID: MessageID, query: Query) async {
        guard let invite = invites[conversation], !invite.isFinished, !invite.answering else { return }
        let candidates = invite.candidates
        invites[conversation]?.answering = true
        invites[conversation]?.lastQuery = queryID
        defer { invites[conversation]?.answering = false }

        let acceptable: [PlaceChoice]
        if let judged = invite.acceptable {
            acceptable = judged
        } else {
            let limits = await ownerLimits()
            var facts: [PlaceChoice: PlaceFacts] = [:]
            for candidate in candidates {
                // Facts come from this phone's own lookup by Maps
                // identifier, never from the friend's message.
                facts[candidate] = (try? await maps.facts(for: candidate)) ?? .unknown
            }
            acceptable = PlaceJudge.acceptable(candidates.map { PlaceCandidate(choice: $0, facts: facts[$0] ?? .unknown) }, limits: limits)
            guard invites[conversation]?.isFinished == false else { return }
            invites[conversation]?.acceptable = acceptable
            invites[conversation]?.facts = facts
        }
        let saysNo = acceptable.isEmpty && organizerIsOnDevice(invite.organizer)
        // A yes or no about a candidate is recorded before it leaves; if the
        // record cannot be kept, or the conversation would pass its limit,
        // nothing is answered (re-review of PR #55, finding 1).
        if !acceptable.isEmpty || saysNo {
            guard await recordAnswered(candidates, in: conversation) else { return }
        }
        guard !acceptable.isEmpty else {
            // The no goes out without asking only to an organizer whose
            // agent runs on its phone, where the policy needs no sheet; to
            // anyone else the phone stays silent rather than show the owner
            // a sheet for a request it never showed them.
            endInvite(conversation, event: .noAgreement, reply: saysNo ? .noOverlap : nil)
            return
        }
        announce(conversation)

        guard let invite = invites[conversation] else { return }
        do {
            let answer = try Answer(query: queryID, issue: .place, status: .answered, acceptable: .places(acceptable))
            try await send(.answer(answer), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom, answering: query)
        } catch {
            // The list belongs to the step before any proposal; once one has
            // arrived, the result no longer describes the current step
            // (ADR 0011, amendment 14).
            guard invites[conversation]?.proposal == nil else { return }
            switch error {
            case OutboxError.denied: endInvite(conversation, event: .blockedByPrivacy, reply: nil)
            // The coordinator applies the pass.
            case OutboxError.consentDeclined: endInvite(conversation, event: nil, reply: nil)
            // The organizer asks again.
            default: break
            }
        }
    }

    /// Adds `candidates` to the conversation's answered set in the ledger.
    /// False when the ledger is unavailable or the set would pass
    /// `ProtocolLimits.maxCandidatesAnsweredPerIssue`.
    func recordAnswered(_ candidates: [PlaceChoice], in conversation: ConversationID) async -> Bool {
        guard let previous = try? await ledger.answeredCandidates(in: conversation) else { return false }
        let all = previous.union(candidates)
        guard all.count <= ProtocolLimits.maxCandidatesAnsweredPerIssue else { return false }
        guard all != previous else { return true }
        return (try? await ledger.recordAnswered(all, in: conversation, at: clock.now())) != nil
    }

    func organizerIsOnDevice(_ peer: PeerID) -> Bool {
        switch cards[peer]?.model {
        case .onDevice?, ModelLocality.none?: true
        default: false
        }
    }

    func announce(_ conversation: ConversationID) {
        guard let invite = invites[conversation], !invite.announced else { return }
        invites[conversation]?.announced = true
        conversationOf[invite.id] = conversation
        continuation.yield(.incoming(invite.id, conversation: conversation, from: invite.organizer, chainedFrom: invite.chainedFrom))
    }

    // MARK: - Proposals

    /// Whether a proposal's checks may still change the card: the request is
    /// open, no send is on its way, and no newer proposal has arrived.
    func isCurrent(_ conversation: ConversationID, generation: UInt64) -> Bool {
        guard let invite = invites[conversation] else { return false }
        return !invite.isFinished && !invite.answering && !invite.accepting && invite.proposalGeneration == generation
    }

    func received(_ proposal: Proposal, id: MessageID, in conversation: ConversationID, generation: UInt64) async {
        // While this phone's list or yes is on its way, possibly waiting on
        // a consent sheet, the card cannot change under the owner: a newer
        // proposal is ignored, and the organizer sends it again.
        guard isCurrent(conversation, generation: generation), let invite = invites[conversation], let acceptable = invite.acceptable,
              let place = validPlace(in: proposal.terms, acceptable: acceptable, organizer: invite.organizer),
              case .peers(let roster)? = proposal.terms[.people]
        else { return }
        // The owner's limits are checked again before the card is shown:
        // they may have changed since the list was sent (rule 6). After a
        // restart the facts are gone, so they are looked up again rather
        // than judged as unknown, which never conflicts.
        var facts = invite.facts[place]
        if facts == nil {
            facts = (try? await maps.facts(for: place)) ?? .unknown
            guard isCurrent(conversation, generation: generation) else { return }
            invites[conversation]?.facts[place] = facts
        }
        let limits = await ownerLimits()
        // Checked after every await, the limit failure included: a newer
        // proposal decides now.
        guard isCurrent(conversation, generation: generation), let invite = invites[conversation],
              invite.proposal?.terms != proposal.terms
        else { return }
        guard PlaceJudge.fit(place, facts: facts ?? .unknown, limits: limits).fits else {
            // A private limit: an ordinary no, like a list where nothing fits.
            endInvite(conversation, event: .noAgreement, reply: .noOverlap)
            return
        }
        let revision = invite.revision + 1
        let plan = Self.plan(base: nil, origin: invite.chainedFrom ?? conversation, roster: roster, terms: proposal.terms, place: place)
        let card = SkillProposal(revision: revision, participants: roster, terms: proposal.terms, plan: plan)
        invites[conversation]?.revision = revision
        invites[conversation]?.proposal = card
        invites[conversation]?.offer = proposal
        invites[conversation]?.proposeID = id
        invites[conversation]?.accepted = false
        emit(invite.id, .proposalReady(card))
    }

    /// The proposed place, if the terms are a proposal this phone can show:
    /// one place from its own acceptable list, a roster that starts with
    /// the organizer and includes this phone, and nothing it did not expect.
    /// A budget or diet value is never expected, so terms carrying one are
    /// ignored.
    func validPlace(in terms: Terms, acceptable: [PlaceChoice], organizer: PeerID) -> PlaceChoice? {
        guard Set(terms.values.keys).isSubset(of: [.place, .people, .time, .activity]),
              case .places(let places)? = terms[.place], places.count == 1, let place = places.first, acceptable.contains(place),
              case .peers(let roster)? = terms[.people], roster.count >= 2, roster.first == organizer, roster.contains(localPeer)
        else { return nil }
        if let time = terms[.time] {
            guard case .slots(let slots) = time, slots.count == 1 else { return nil }
        }
        if let activity = terms[.activity] {
            guard case .keywords(let words) = activity, words.count == 1 else { return nil }
        }
        return place
    }

    func inviteAnswer(_ conversation: ConversationID, _ answer: OwnerAnswer) async throws {
        guard let invite = invites[conversation], !invite.isFinished, let proposal = invite.proposal else {
            throw PickAPlaceError.notWaitingForYou
        }
        switch answer {
        case .accept(let revision):
            guard revision == proposal.revision else { throw PickAPlaceError.staleProposal }
            // A second tap while the first is on its way changes nothing.
            guard !invite.accepted, !invite.accepting else { return }
            invites[conversation]?.accepting = true
            let acceptance = Acceptance(proposal: invite.proposeID ?? MessageID(), terms: proposal.terms)
            let result = await trackedSend(.accept(acceptance), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom,
                                           accepting: invite.offer)
            invites[conversation]?.accepting = false
            // A yes to a proposal that has since been replaced reports
            // nothing (ADR 0011, amendment 14).
            guard invites[conversation]?.proposal?.revision == revision else { return }
            switch result {
            case nil:
                break
            case is CancellationError?:
                // Withdrawn or ended while the send waited; nothing left.
                return
            case OutboxError.consentDeclined?:
                // The coordinator applies the pass; like any pass, nothing
                // is sent.
                endInvite(conversation, event: nil, reply: nil)
                return
            case OutboxError.denied?:
                // No yes left the phone, so this looks like a pass.
                endInvite(conversation, event: .blockedByPrivacy, reply: nil)
                return
            case let error?:
                // Unreachable for now: the owner can tap again.
                throw error
            }
            guard let current = invites[conversation], !current.isFinished, current.proposal?.revision == revision else { return }
            invites[conversation]?.accepted = true
            emit(invite.id, .ownerAccepted(revision: revision))
            spawnWaitForConfirmation(conversation)
        case .pass:
            // After a yes, passing takes the yes back: the state machine
            // calls that withdrawing.
            leave(conversation, event: invite.accepted || invite.accepting ? .withdrawn : .ownerPassed)
        case .reply:
            throw PickAPlaceError.notWaitingForYou
        }
    }

    func spawnAcceptance(_ conversation: ConversationID) {
        guard let invite = invites[conversation], let proposal = invite.proposal else { return }
        let acceptance = Acceptance(proposal: invite.proposeID ?? MessageID(), terms: proposal.terms)
        spawn(conversation) { service in
            await service.trySend(.accept(acceptance), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom,
                                  accepting: invite.offer)
        }
    }

    /// Repeats the yes until the organizer confirms, in case either message
    /// was lost. The request's own deadline ends it if the organizer never
    /// does.
    func spawnWaitForConfirmation(_ conversation: ConversationID) {
        spawn(conversation) { service in
            var interval = service.configuration.retryInterval
            while let invite = service.invites[conversation], !invite.isFinished, invite.accepted {
                guard let next = await service.pause(interval) else { return }
                interval = next
                guard let invite = service.invites[conversation], !invite.isFinished, invite.accepted else { return }
                service.spawnAcceptance(conversation)
            }
        }
    }

    /// The organizer's confirmation: the accepted terms, with everyone who
    /// said yes. It may list fewer people than the proposal, never others.
    func confirmed(_ acceptance: Acceptance, in conversation: ConversationID) {
        guard let invite = invites[conversation], invite.accepted, let proposal = invite.proposal,
              case .peers(let proposed)? = proposal.terms[.people], case .peers(let final)? = acceptance.terms[.people],
              case .places(let places)? = proposal.terms[.place], let place = places.first,
              Set(acceptance.terms.values.keys) == Set(proposal.terms.values.keys),
              acceptance.terms.values.allSatisfy({ $0.key == .people || $0.value == proposal.terms[$0.key] }),
              final.count >= 2, final.first == invite.organizer, final.contains(localPeer), Set(final).isSubset(of: proposed)
        else { return }
        invites[conversation]?.finished = true
        invites[conversation]?.finalRoster = final
        cancelTasks(conversation)
        remember(conversation)
        emit(invite.id, .everyoneConfirmed(revision: proposal.revision))
        continuation.yield(.produced(invite.id, .placeChoice(place)))
        if let attendees = try? Attendees(final) {
            continuation.yield(.produced(invite.id, .attendees(attendees)))
        }
    }

    /// A confirmed plan lost someone: the same terms with fewer people,
    /// still including this phone and the organizer.
    func rosterShrank(_ acceptance: Acceptance, in conversation: ConversationID) {
        guard let invite = invites[conversation], let roster = invite.finalRoster, let proposal = invite.proposal,
              case .peers(let shorter)? = acceptance.terms[.people],
              Set(acceptance.terms.values.keys) == Set(proposal.terms.values.keys),
              acceptance.terms.values.allSatisfy({ $0.key == .people || $0.value == proposal.terms[$0.key] }),
              shorter.count >= 2, shorter.count < roster.count, shorter.first == invite.organizer, shorter.contains(localPeer),
              Set(shorter).isSubset(of: roster), let attendees = try? Attendees(shorter)
        else { return }
        invites[conversation]?.finalRoster = shorter
        continuation.yield(.produced(invite.id, .attendees(attendees)))
    }

    // MARK: - Ending

    /// The owner passes or withdraws. What the organizer hears never says
    /// which (ADR 0017: "If you pass, they just won't see it"):
    /// - before any proposal, an ordinary no, so the organizer chooses
    ///   without this phone;
    /// - after a yes, an ordinary no that takes the yes back;
    /// - a pass on a card without a yes sends nothing, so it looks exactly
    ///   like silence and resolves at the organizer's confirm deadline
    ///   (ADR 0020, decision 9).
    func leave(_ conversation: ConversationID, event: InteractionEvent) {
        guard let invite = invites[conversation] else { return }
        if invite.isFinished {
            // Withdrawing from a confirmed plan takes the yes back like any
            // other: the organizer shortens the roster for everyone left.
            guard invite.finalRoster != nil else { return }
            invites[conversation]?.finalRoster = nil
            emit(invite.id, .withdrawn)
            startWithdrawal(invite)
            return
        }
        guard invite.accepted || invite.accepting else {
            endInvite(conversation, event: event, reply: invite.proposal == nil ? .noOverlap : nil)
            return
        }
        // Taking a yes back must reach the organizer, or it would confirm a
        // roster with someone who left: the no is kept in the ledger and
        // retried until the organizer acknowledges it, across relaunches.
        endInvite(conversation, event: event, reply: nil)
        startWithdrawal(invite)
    }

    func startWithdrawal(_ invite: Invite) {
        let withdrawal = PendingWithdrawal(conversation: invite.conversation, organizer: invite.organizer, proposal: invite.proposeID,
                                           chainedFrom: invite.chainedFrom, since: clock.now())
        spawn(invite.conversation) { try? await $0.ledger.recordWithdrawal(withdrawal) }
        retryWithdrawal(withdrawal)
    }

    /// The organizer withdrew a confirmed plan: it is over on this phone too.
    func planCalledOff(_ conversation: ConversationID) {
        guard let invite = invites[conversation], invite.finalRoster != nil else { return }
        invites[conversation]?.finalRoster = nil
        emit(invite.id, .withdrawn)
    }

    /// Sends the no again, with backoff, until the organizer acknowledges it
    /// or a day has passed.
    func retryWithdrawal(_ withdrawal: PendingWithdrawal) {
        let conversation = withdrawal.conversation
        pendingWithdrawals[conversation] = withdrawal
        spawn(conversation) { service in
            var interval = service.configuration.retryInterval
            while service.pendingWithdrawals[conversation] == withdrawal {
                guard service.clock.now().timeIntervalSince(withdrawal.since) < PickAPlaceLedgerState.withdrawalLifetime else {
                    service.pendingWithdrawals[conversation] = nil
                    try? await service.ledger.clearWithdrawal(conversation)
                    return
                }
                let rejection = Rejection(proposal: withdrawal.proposal ?? MessageID(), reason: .noOverlap)
                await service.trySend(.reject(rejection), to: withdrawal.organizer, conversation: conversation, chainedFrom: withdrawal.chainedFrom)
                guard let next = await service.pause(interval) else { return }
                interval = next
            }
        }
    }

    /// Ends this phone's part. `reply` is sent only for the owner's own
    /// explicit choices, never for a private limit.
    func endInvite(_ conversation: ConversationID, event: InteractionEvent?, reply: Rejection.Reason?) {
        guard let invite = invites[conversation], !invite.isFinished else { return }
        invites[conversation]?.finished = true
        cancelTasks(conversation)
        if invite.announced, let event { emit(invite.id, event) }
        if let reply {
            let rejection = Rejection(proposal: invite.proposeID ?? invite.lastQuery ?? MessageID(), reason: reply)
            spawn(conversation) { service in
                await service.trySend(.reject(rejection), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom)
            }
        }
        remember(conversation)
    }

    /// Keeps a bounded number of ended requests, so late retries are
    /// ignored instead of starting over.
    func remember(_ conversation: ConversationID) {
        endedInvites.append(conversation)
        while endedInvites.count > configuration.maxRememberedRequests {
            let oldest = endedInvites.removeFirst()
            if let invite = invites.removeValue(forKey: oldest) { conversationOf[invite.id] = nil }
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
