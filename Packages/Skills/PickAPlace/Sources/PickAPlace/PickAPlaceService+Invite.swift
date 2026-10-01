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
    var accepted = false
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
        guard case .query(let query) = envelope.body, query.issue == .place, case .places(let candidates) = query.candidates else { return }
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
        requestTimes[envelope.sender] = recent + [clock.now()]
        let conversation = envelope.conversation
        invites[conversation] = Invite(id: InteractionID(), conversation: conversation, organizer: envelope.sender, chainedFrom: envelope.chainedFrom)
        spawnInviteDeadline(conversation)
        spawn(conversation) { await $0.judgeAndAnswer(conversation, query: envelope.id, candidates: candidates) }
    }

    /// Ends a request the organizer stops answering: an honest organizer
    /// settles it within its answer and confirm windows, so a request still
    /// open well after that is over. Without this, a silent or crashed
    /// organizer would hold a live slot, and Home's row, forever.
    func spawnInviteDeadline(_ conversation: ConversationID) {
        let limit = configuration.answerWindow + configuration.confirmWindow * 2
        spawn(conversation) { service in
            guard (try? await service.clock.sleep(limit)) != nil, !Task.isCancelled else { return }
            service.endInvite(conversation, event: .expired, reply: nil)
        }
    }

    func inviteReceived(_ envelope: Envelope) {
        let conversation = envelope.conversation
        guard let invite = invites[conversation], envelope.sender == invite.organizer, !invite.isFinished else { return }
        switch envelope.body {
        case .query(let query):
            guard query.issue == .place, case .places(let candidates) = query.candidates else { return }
            spawn(conversation) { await $0.judgeAndAnswer(conversation, query: envelope.id, candidates: candidates) }
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
    /// phone looks up, then answers with the ones that fit. A retry of the
    /// same query gets the same list. When nothing fits, the phone says
    /// nothing at all, exactly as if its owner had not answered yet: a
    /// "none of these" would tell a probing friend about the owner's limits
    /// without a consent sheet (ADR 0230).
    func judgeAndAnswer(_ conversation: ConversationID, query: MessageID, candidates: [PlaceChoice]) async {
        guard let invite = invites[conversation], !invite.isFinished, !invite.answering else { return }
        invites[conversation]?.answering = true
        invites[conversation]?.lastQuery = query
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
        guard !acceptable.isEmpty else {
            endInvite(conversation, event: .noAgreement, reply: nil)
            return
        }
        announce(conversation)

        guard let invite = invites[conversation] else { return }
        do {
            let answer = try Answer(query: query, issue: .place, status: .answered, acceptable: .places(acceptable))
            try await send(.answer(answer), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom)
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
            // A private limit: silent, like a list where nothing fits.
            endInvite(conversation, event: .noAgreement, reply: nil)
            return
        }
        let revision = invite.revision + 1
        let plan = Self.plan(base: nil, origin: invite.chainedFrom ?? conversation, roster: roster, terms: proposal.terms, place: place)
        let card = SkillProposal(revision: revision, participants: roster, terms: proposal.terms, plan: plan)
        invites[conversation]?.revision = revision
        invites[conversation]?.proposal = card
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
            let result = await trackedSend(.accept(acceptance), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom)
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
                // The coordinator applies the pass.
                endInvite(conversation, event: nil, reply: .declinedByOwner)
                return
            case OutboxError.denied?:
                endInvite(conversation, event: .blockedByPrivacy, reply: .declinedByOwner)
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
            let event: InteractionEvent = invite.accepted || invite.accepting ? .withdrawn : .ownerPassed
            endInvite(conversation, event: event, reply: .declinedByOwner)
        case .reply:
            throw PickAPlaceError.notWaitingForYou
        }
    }

    func spawnAcceptance(_ conversation: ConversationID) {
        guard let invite = invites[conversation], let proposal = invite.proposal else { return }
        let acceptance = Acceptance(proposal: invite.proposeID ?? MessageID(), terms: proposal.terms)
        spawn(conversation) { service in
            await service.trySend(.accept(acceptance), to: invite.organizer, conversation: conversation, chainedFrom: invite.chainedFrom)
        }
    }

    /// Repeats the yes until the organizer confirms, in case either message
    /// was lost; gives up when the confirm window closes.
    func spawnWaitForConfirmation(_ conversation: ConversationID) {
        let deadline = clock.now().addingTimeInterval(Self.seconds(configuration.confirmWindow))
        spawn(conversation) { service in
            var interval = service.configuration.retryInterval
            while let invite = service.invites[conversation], !invite.isFinished, invite.accepted {
                guard let next = await service.pause(interval) else { return }
                interval = next
                guard service.clock.now() < deadline else {
                    service.endInvite(conversation, event: .expired, reply: nil)
                    return
                }
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
        cancelTasks(conversation)
        remember(conversation)
        emit(invite.id, .everyoneConfirmed(revision: proposal.revision))
        continuation.yield(.produced(invite.id, .placeChoice(place)))
        if let attendees = try? Attendees(final) {
            continuation.yield(.produced(invite.id, .attendees(attendees)))
        }
    }

    // MARK: - Ending

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
