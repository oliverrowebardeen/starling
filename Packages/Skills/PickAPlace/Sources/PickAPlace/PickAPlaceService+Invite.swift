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
    /// Whether this request's admission is durably in the ledger. Nothing
    /// is judged or answered before it is (issue #65).
    var admitted = false
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
    /// What the request is on this phone's plan, from this phone's own copy
    /// of it; nil when the request is not chained from a plan.
    var kind: PlaceRequestKind?
    /// The newest proposal that arrived while this phone's own list or yes
    /// was still on its way, handled once that send returns. The organizer
    /// may send it the moment it has the list or yes, before this phone's
    /// send has returned (issue #121).
    var waitingProposal: (proposal: Proposal, id: MessageID, generation: UInt64)?
    /// A confirmation that arrived while this phone's yes was still on its
    /// way, taken once the yes has gone (issue #121).
    var waitingConfirmation: Acceptance?
    /// The proposals this phone's yes named, for the current card, most
    /// recent last and bounded: a confirmation must name one of them.
    var yesNamed: [MessageID] = []

    var isFinished: Bool { finished }
    /// A change of a plan's place: the plan's whole roster must agree, and
    /// a yes is final once sent (ADR 0233).
    var isChange: Bool { if case .placeChange? = kind { true } else { false } }
}

extension PickAPlaceService {
    /// A query from a friend for a conversation this phone has not seen.
    func newInvite(_ envelope: Envelope) {
        guard case .query(let query) = envelope.body, query.issue == .place, case .places(let candidates) = query.candidates,
              candidates.count <= ProtocolLimits.maxCandidatesAnsweredPerIssue
        else { return }
        // Every admitted request holds its slot until the deadline an
        // unanswered one would hold, however it ended: a pass that freed
        // its slot at once would let a friend tell it from an ignored card
        // by whether a fifth request is answered (final privacy review of
        // PR #55). Counted from the persisted admission times, so a
        // relaunch frees nothing either.
        let now = clock.now()
        let slotStart = now.addingTimeInterval(-Self.seconds(slotDuration))
        requestTimes = requestTimes.mapValues { $0.filter { $0 > min(slotStart, now.addingTimeInterval(-3_600)) } }.filter { !$0.value.isEmpty }
        let held = requestTimes.values.reduce(0) { $0 + $1.filter { $0 > slotStart }.count }
        let mine = requestTimes[envelope.sender] ?? []
        guard held < configuration.maxLiveRequests,
              mine.filter({ $0 > slotStart }).count < configuration.maxLiveRequestsPerFriend,
              mine.filter({ $0 > now.addingTimeInterval(-3_600) }).count < configuration.maxNewRequestsPerFriendPerHour
        else { return }
        requestTimes[envelope.sender] = mine + [now]
        let conversation = envelope.conversation
        let sender = envelope.sender
        invites[conversation] = Invite(id: InteractionID(), conversation: conversation, organizer: envelope.sender,
                                       chainedFrom: envelope.chainedFrom, candidates: candidates)
        spawnInviteDeadline(conversation)
        // The admission is written, and awaited, before anything is judged
        // or answered. If it cannot be written, the request is dropped
        // without a word and its conversation retired: a limit that a
        // relaunch could reset is no limit (issue #65).
        spawn(conversation) { service in
            do {
                try await service.ledger.recordAdmission(sender, at: now)
                // What the request is on this phone's own plan, recorded for
                // its whole life before anything is answered (ADR 0233).
                if let chainedFrom = envelope.chainedFrom {
                    let kind = Self.kind(of: await service.plans(chainedFrom))
                    try await service.ledger.recordRequestKind(kind, for: conversation, at: now)
                    service.invites[conversation]?.kind = kind
                }
            } catch {
                service.endInvite(conversation, event: nil, reply: nil)
                return
            }
            service.invites[conversation]?.admitted = true
            await service.judgeAndAnswer(conversation, queryID: envelope.id, query: query)
        }
    }

    /// Ends a request the organizer stops answering. An honest organizer
    /// settles it within its answer window, a confirm window for friends,
    /// and one more for its own owner, so a request still open after a
    /// further confirm window is over. Without this, a silent or crashed
    /// organizer would hold a live slot, and Home's row, forever. A friend
    /// who said yes waits this long too, so it never gives up on a plan
    /// the organizer can still confirm.
    func spawnInviteDeadline(_ conversation: ConversationID) {
        let limit = slotDuration
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
            // A retry repeats the terms and the revision it names; the same
            // terms at another revision are a new proposal, which needs a
            // fresh decision from the owner.
            if let current = invite.proposal, current.terms == proposal.terms, invite.offer?.round == proposal.round {
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
        guard let invite = invites[conversation], !invite.isFinished, invite.admitted, !invite.answering else { return }
        let candidates = invite.candidates
        invites[conversation]?.answering = true
        invites[conversation]?.lastQuery = queryID
        defer {
            invites[conversation]?.answering = false
            ownSendReturned(conversation)
        }

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
        guard !acceptable.isEmpty else {
            // The no goes out without asking only to an organizer whose
            // agent runs on its phone, where the policy needs no sheet; to
            // anyone else the phone stays silent rather than show the owner
            // a sheet for a request it never showed them. A no about these
            // candidates teaches as much as a list, so it spends the same
            // budget first: the Outbox reserves an answer's candidates, and
            // the service reserves a no's (ADR 0021).
            var saysNo = false
            if organizerIsOnDevice(invite.organizer) { saysNo = await reserve(candidates, to: invite.organizer, in: conversation) }
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
            // The conversation's answer budget is spent, or it was retired,
            // or the ledger cannot say: nothing more is answered here.
            case OutboxError.answerLimitReached, OutboxError.conversationRetired, OutboxError.answerWithoutItsQuery:
                endInvite(conversation, event: .noAgreement, reply: nil)
            // The organizer asks again.
            default: break
            }
        }
    }

    /// Spends the conversation's answer budget on a no about `places`
    /// (ADR 0021). False when the ledger refuses or cannot say.
    func reserve(_ places: [PlaceChoice], to organizer: PeerID, in conversation: ConversationID) async -> Bool {
        guard !places.isEmpty else { return true }
        return (try? await conversations.reserve(IssueValue.places(places).candidates, issue: .place, to: organizer, in: conversation)) == true
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
    /// Whether the proposal of `generation` can be handled now. If only this
    /// phone's own list or yes, still on its way, is in the way, the
    /// proposal is kept and handled when that send returns, rather than
    /// dropped and left to the organizer's next retry (issue #121).
    func readyForProposal(_ proposal: Proposal, id: MessageID, in conversation: ConversationID, generation: UInt64) -> Bool {
        guard let invite = invites[conversation], !invite.isFinished, invite.proposalGeneration == generation else { return false }
        guard !invite.answering, !invite.accepting else {
            invites[conversation]?.waitingProposal = (proposal, id, generation)
            return false
        }
        return true
    }

    /// This phone's list or yes has returned, sent or not: a proposal or a
    /// confirmation that arrived meanwhile is handled now (issue #121).
    func ownSendReturned(_ conversation: ConversationID) {
        guard let invite = invites[conversation], !invite.isFinished, !invite.answering, !invite.accepting else { return }
        if let waiting = invite.waitingConfirmation {
            invites[conversation]?.waitingConfirmation = nil
            if invite.accepted { confirmed(waiting, in: conversation) }
        }
        if let waiting = invites[conversation]?.waitingProposal, invites[conversation]?.isFinished == false {
            invites[conversation]?.waitingProposal = nil
            spawn(conversation) { await $0.received(waiting.proposal, id: waiting.id, in: conversation, generation: waiting.generation) }
        }
    }

    func received(_ proposal: Proposal, id: MessageID, in conversation: ConversationID, generation: UInt64) async {
        // While this phone's list or yes is on its way, possibly waiting on
        // a consent sheet, the card cannot change under the owner: the
        // newest proposal waits until that send returns (issue #121).
        guard readyForProposal(proposal, id: id, in: conversation, generation: generation), let invite = invites[conversation],
              let acceptable = invite.acceptable,
              let place = validPlace(in: proposal.terms, acceptable: acceptable, organizer: invite.organizer),
              case .peers(let roster)? = proposal.terms[.people]
        else { return }
        // A change of place asks this phone's plan's whole roster, over the
        // plan's own revision: anything else is not shown (ADR 0233).
        if case .placeChange(let everyone, let revision, let time, let activity)? = invite.kind {
            guard Set(roster) == Set(everyone), revision < UInt32(ProtocolLimits.maxNegotiationRounds - 1),
                  UInt32(proposal.round) == revision + 1,
                  // Only the place changes: the time and activity stay.
                  proposal.terms[.time] == time.map({ .slots([$0]) }), proposal.terms[.activity] == activity.map({ .keywords([$0]) })
            else { return }
        }
        // The owner's limits are checked again before the card is shown:
        // they may have changed since the list was sent (rule 6). After a
        // restart the facts are gone, so they are looked up again rather
        // than judged as unknown, which never conflicts.
        var facts = invite.facts[place]
        if facts == nil {
            facts = (try? await maps.facts(for: place)) ?? .unknown
            guard readyForProposal(proposal, id: id, in: conversation, generation: generation) else { return }
            invites[conversation]?.facts[place] = facts
        }
        let limits = await ownerLimits()
        // Checked after every await, the limit failure included: a newer
        // proposal decides now.
        guard readyForProposal(proposal, id: id, in: conversation, generation: generation), let invite = invites[conversation],
              invite.proposal?.terms != proposal.terms || invite.offer?.round != proposal.round
        else { return }
        guard PlaceJudge.fit(place, facts: facts ?? .unknown, limits: limits).fits else {
            // A private limit: an ordinary no, like a list where nothing
            // fits, once it has spent the budget for the place.
            let saysNo = await reserve([place], to: invite.organizer, in: conversation)
            guard readyForProposal(proposal, id: id, in: conversation, generation: generation) else { return }
            endInvite(conversation, event: .noAgreement, reply: saysNo ? .noOverlap : nil)
            return
        }
        let revision = invite.revision + 1
        // A request on a plan names, in its round, the revision the agreed
        // plan will have, so this phone's plan names it too (ADR 0233). Lane
        // E applies it only over the revision just before. Stored with the
        // card, it also keeps the offer's revision across a restart; a
        // request on no plan names 0.
        let planRevision = UInt32(proposal.round)
        // A request naming a plan this phone does not hold changes no plan
        // here: its agreed plan is its own, at revision 0, which applies
        // over no plan's revision (ADR 0233).
        let notHeld = invite.kind == .planNotHeld
        let plan = Self.plan(base: nil, origin: notHeld ? conversation : invite.chainedFrom ?? conversation, roster: roster,
                             terms: proposal.terms, place: place, revision: notHeld ? 0 : planRevision)
        let card = SkillProposal(revision: revision, participants: roster, terms: proposal.terms, plan: plan)
        invites[conversation]?.revision = revision
        invites[conversation]?.proposal = card
        invites[conversation]?.offer = proposal
        invites[conversation]?.proposeID = id
        invites[conversation]?.accepted = false
        invites[conversation]?.yesNamed = []
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
            // However this ends, a proposal or confirmation that arrived
            // while the yes was on its way is handled after (issue #121).
            defer { ownSendReturned(conversation) }
            // A change applies only over the plan it was made for: if the
            // plan moved on meanwhile, the card closes and nothing is sent
            // (ADR 0233).
            if case .placeChange(_, let planRevision, _, _)? = invite.kind {
                let current: Plan? = if let chainedFrom = invite.chainedFrom { await plans(chainedFrom) } else { nil }
                guard let current, current.revision == planRevision, current.place != nil else {
                    invites[conversation]?.accepting = false
                    endInvite(conversation, event: .noAgreement, reply: nil)
                    throw PickAPlaceError.planChangedMeanwhile
                }
            }
            // The lookup waited: the card must still be this one.
            guard let current = invites[conversation], !current.isFinished, current.proposal?.revision == revision else {
                invites[conversation]?.accepting = false
                return
            }
            // What this yes names is recorded before it goes, so only a
            // confirmation of it is taken, across relaunches.
            guard let named = await recordYes(in: conversation) else {
                invites[conversation]?.accepting = false
                throw PickAPlaceError.ledgerUnavailable
            }
            let acceptance = Acceptance(proposal: named, terms: proposal.terms)
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
            guard !(invite.isChange && (invite.accepted || invite.accepting)) else { throw PickAPlaceError.yesIsFinal }
            // After a yes, passing takes the yes back: the state machine
            // calls that withdrawing.
            leave(conversation, event: invite.accepted || invite.accepting ? .withdrawn : .ownerPassed)
        case .reply:
            throw PickAPlaceError.notWaitingForYou
        }
    }

    func spawnAcceptance(_ conversation: ConversationID) {
        guard let invite = invites[conversation], let proposal = invite.proposal else { return }
        spawn(conversation) { service in
            // Recorded before it goes; a yes that cannot be recorded is not
            // sent.
            guard let named = await service.recordYes(in: conversation),
                  service.invites[conversation]?.proposal?.revision == proposal.revision
            else { return }
            await service.trySend(.accept(Acceptance(proposal: named, terms: proposal.terms)), to: invite.organizer, conversation: conversation,
                                  chainedFrom: invite.chainedFrom, accepting: invite.offer)
        }
    }

    /// Adds the proposal this phone's next yes names to the ones its yes
    /// has named for the current card, and records them, before the yes is
    /// sent. Returns the proposal it names, or nil if it could not be
    /// recorded.
    func recordYes(in conversation: ConversationID) async -> MessageID? {
        guard let invite = invites[conversation], let proposal = invite.proposal else { return nil }
        let named = invite.proposeID ?? MessageID()
        var yesNamed = invite.yesNamed.filter { $0 != named } + [named]
        if yesNamed.count > Self.maxRememberedProposals { yesNamed.removeFirst(yesNamed.count - Self.maxRememberedProposals) }
        do {
            try await ledger.recordYes(RecordedYes(revision: proposal.revision, proposals: yesNamed, at: clock.now()), for: conversation)
        } catch {
            return nil
        }
        // A newer card arrived while the record was written: this yes is
        // not for it.
        guard invites[conversation]?.proposal?.revision == proposal.revision else { return nil }
        invites[conversation]?.yesNamed = yesNamed
        return named
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
        // The yes may still be on its way, its send not yet returned: the
        // confirmation waits for it (issue #121).
        if let invite = invites[conversation], !invite.isFinished, !invite.accepted, invite.accepting {
            invites[conversation]?.waitingConfirmation = acceptance
            return
        }
        // It must confirm this phone's own yes: name a proposal the yes named.
        guard let invite = invites[conversation], invite.accepted, let proposal = invite.proposal,
              invite.yesNamed.contains(acceptance.proposal),
              case .peers(let proposed)? = proposal.terms[.people], case .peers(let final)? = acceptance.terms[.people],
              case .places(let places)? = proposal.terms[.place], let place = places.first,
              Set(acceptance.terms.values.keys) == Set(proposal.terms.values.keys),
              acceptance.terms.values.allSatisfy({ $0.key == .people || $0.value == proposal.terms[$0.key] }),
              final.count >= 2, final.first == invite.organizer, final.contains(localPeer), Set(final).isSubset(of: proposed),
              // A change of place is confirmed only with everyone in it.
              !invite.isChange || Set(final) == Set(proposed)
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
        // A confirmed change of place never loses anyone (ADR 0233).
        guard let invite = invites[conversation], !invite.isChange, let roster = invite.finalRoster, let proposal = invite.proposal,
              invite.yesNamed.contains(acceptance.proposal),
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
        // A yes to a change of place is final once sent (ADR 0233).
        // A yes on its way counts: the organizer may already have it.
        guard !(invite.isChange && (invite.accepted || invite.accepting || invite.finalRoster != nil)) else { return }
        if invite.isFinished {
            // Withdrawing from a confirmed plan takes the yes back like any
            // other: the organizer shortens the roster for everyone left.
            guard invite.finalRoster != nil else { return }
            invites[conversation]?.finalRoster = nil
            startWithdrawal(invite, event: .withdrawn)
            return
        }
        guard invite.accepted || invite.accepting else {
            endInvite(conversation, event: event, reply: invite.proposal == nil ? .noOverlap : nil)
            return
        }
        // Taking a yes back must reach the organizer, or it would confirm a
        // roster with someone who left: the no is kept in the ledger and
        // retried until the organizer acknowledges it, across relaunches,
        // and only then is the conversation retired.
        endInvite(conversation, event: nil, reply: nil, retiring: false)
        startWithdrawal(invite, event: event)
    }

    /// Takes a yes back. Retiring would stop the no being retried, so the
    /// ending's durability comes from the ledger instead: the withdrawal is
    /// recorded before `event` is reported, the record blocks reopening
    /// across relaunches until the conversation is retired, and it is
    /// cleared only once the retirement has succeeded. If it cannot be
    /// recorded, the no goes out once and the conversation is retired
    /// before the ending is reported (ADR 0021; lane E's review).
    func startWithdrawal(_ invite: Invite, event: InteractionEvent) {
        let conversation = invite.conversation
        let withdrawal = PendingWithdrawal(conversation: conversation, organizer: invite.organizer, proposal: invite.proposeID,
                                           chainedFrom: invite.chainedFrom, since: clock.now(), interaction: invite.id)
        pendingWithdrawals[conversation] = withdrawal
        spawn(conversation) { service in
            do {
                try await service.ledger.recordWithdrawal(withdrawal)
                service.emit(invite.id, event)
                service.retryWithdrawal(withdrawal)
            } catch {
                service.pendingWithdrawals[conversation] = nil
                let no = MessageBody.reject(Rejection(proposal: withdrawal.proposal ?? MessageID(), reason: .noOverlap))
                service.finish(conversation, interaction: invite.id, event: event, goodbyes: [(invite.organizer, no)],
                               chainedFrom: invite.chainedFrom)
            }
        }
    }

    /// The organizer withdrew a confirmed plan: it is over on this phone too.
    func planCalledOff(_ conversation: ConversationID) {
        // A confirmed change of place is final; it is not called off
        // (ADR 0233).
        guard let invite = invites[conversation], invite.finalRoster != nil, !invite.isChange else { return }
        invites[conversation]?.finalRoster = nil
        finish(conversation, interaction: invite.id, event: .withdrawn)
    }

    /// The organizer heard this phone take its yes back: nothing more is
    /// owed, so the conversation is retired.
    func withdrawalAcknowledged(_ conversation: ConversationID) {
        guard pendingWithdrawals.removeValue(forKey: conversation) != nil else { return }
        // The record is cleared only once the retirement is durable; if it
        // fails, the record stays and the next launch retires it.
        spawn(conversation) { service in
            do {
                try await service.outbox.retire(conversation)
                try? await service.ledger.clearWithdrawal(conversation)
            } catch {
                service.unretired.insert(conversation)
            }
        }
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
                    // A day without an answer: the organizer is gone.
                    service.withdrawalAcknowledged(conversation)
                    return
                }
                let rejection = Rejection(proposal: withdrawal.proposal ?? MessageID(), reason: .noOverlap)
                await service.trySend(.reject(rejection), to: withdrawal.organizer, conversation: conversation, chainedFrom: withdrawal.chainedFrom,
                                      interaction: withdrawal.interaction)
                guard let next = await service.pause(interval) else { return }
                interval = next
            }
        }
    }

    /// Ends this phone's part, sends `reply` if any, and retires the
    /// conversation (ADR 0021). A yes taken back retires it only once the
    /// organizer has heard the no (`retiring: false`).
    func endInvite(_ conversation: ConversationID, event: InteractionEvent?, reply: Rejection.Reason?, retiring: Bool = true) {
        guard let invite = invites[conversation], !invite.isFinished else { return }
        invites[conversation]?.finished = true
        cancelTasks(conversation)
        if retiring {
            let goodbye: [(PeerID, MessageBody)] = reply.map {
                [(invite.organizer, .reject(Rejection(proposal: invite.proposeID ?? invite.lastQuery ?? MessageID(), reason: $0)))]
            } ?? []
            finish(conversation, interaction: invite.announced ? invite.id : nil, event: event, goodbyes: goodbye, chainedFrom: invite.chainedFrom)
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
