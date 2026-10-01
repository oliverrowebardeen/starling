import Foundation
import StarlingCore
import StarlingNegotiation

// Invite mode (ADR 0020, ADR 0210 decisions 18 to 21): the starter's plan
// goes straight to each friend as a card. No mutual reveal: an invitation is
// meant to be seen. The starter keeps whoever said I'm in, then confirms.

extension DownForService {
    /// How many live invitation cards one friend can put on this phone at
    /// once, so a friend cannot flood Home.
    static let maxInvitationsPerFriend = 3

    // MARK: - Starter

    /// The plan an invitation offers: the first block of the starter's own
    /// free time, up to two hours, and its first activity. Nothing the
    /// starter keeps on the phone (budget, place) goes in it.
    func invitationTerms(for profile: DownForProfile, now: Date) -> Terms? {
        guard let activity = profile.liked.first else { return nil }
        let slots = profile.tokens(now: now).slots
        guard let first = slots.first else { return nil }
        var end = first.endMinute
        for slot in slots.dropFirst() where slot.startMinute == end && slot.endMinute - first.startMinute <= configuration.maxPlanMinutes {
            end = slot.endMinute
        }
        guard let time = try? TimeSlot(startMinute: first.startMinute, endMinute: end) else { return nil }
        return try? Terms([.time: .slots([time]), .activity: .keywords([activity])])
    }

    /// Sends the invitation to one friend, as the starter.
    func invite(_ id: InteractionID, _ peer: PeerID) async {
        guard let request = requests[id], let terms = request.invitation, request.group == nil, request.mirror.state == .negotiating,
              request.record.participants.contains(peer), !request.settled.contains(peer), !request.unsupported.contains(peer),
              reachable.contains(peer), request.runs[peer, default: 0] < configuration.maxRunsPerPeer,
              !runs.values.contains(where: { $0.request == id && $0.key.peer == peer }),
              let proposal = try? Proposal(round: 0, terms: terms)
        else { return }
        let key = RunKey(conversation: request.conversation, peer: peer)
        runs[key] = Run(invitation: key, request: id, role: .hub, chainedFrom: request.record.chainedFrom, terms: terms)
        debitRun(id, peer, by: 1)
        // Resent with backoff until the friend answers or the window passes.
        await transmit([.propose(proposal)], in: key, awaitingReply: true, attemptLimit: .max, backsOff: true)
    }

    /// The window for friends to answer an invitation.
    func armInvitationWindow(_ id: InteractionID) {
        let window = configuration.ownerWindow
        requests[id]?.quiet = Task { [weak self] in
            try? await Task.sleep(for: window)
            await self?.lockInvitation(id)
        }
    }

    /// A friend said I'm in to the invitation. Once every friend has, the
    /// starter need not wait for the window.
    func invitationAccepted(in id: InteractionID) {
        guard let request = requests[id], request.group == nil else { return }
        let everyone = request.record.participants.filter { !request.unsupported.contains($0) }
        let accepted = everyone.filter { runs[RunKey(conversation: request.conversation, peer: $0)]?.accepted == true }
        if accepted.count == everyone.count { lockInvitation(id) }
    }

    /// Shows the starter who is in, as the card it confirms: the invitation
    /// plus, for three or more, the roster of the friends who said I'm in.
    /// Friends who did not answer are told "no plan" and their cards go.
    func lockInvitation(_ id: InteractionID) {
        guard let request = requests[id], request.invitation != nil, request.group == nil, request.mirror.state == .negotiating else { return }
        request.quiet?.cancel()
        requests[id]?.quiet = nil
        let acceptors = request.record.participants.filter { runs[RunKey(conversation: request.conversation, peer: $0)]?.accepted == true }
        for run in runs.values where run.request == id && run.role == .hub && !run.accepted {
            enqueue(.notify(run.notice, .expired), for: run.key.peer)
            end(run.key, .timedOut, react: false)
        }
        guard !acceptors.isEmpty else {
            endRequest(id, with: .noAgreement)
            return
        }
        showInvitation(to: acceptors, in: id)
    }

    /// The starter's card for these friends. Also used when one of them is
    /// lost later: the rest get a new revision with a smaller roster.
    func showInvitation(to members: [PeerID], in id: InteractionID) {
        guard let request = requests[id], let invitation = request.invitation, let first = members.first else { return }
        var values = invitation.values
        if members.count >= 2 { values[.people] = .peers([localPeer] + members) }
        guard let terms = try? Terms(values), let roster = DownForProfile.roster(of: terms, hub: localPeer, member: first) else { return }
        let revision = (request.mirror.proposalRevision ?? 0) + 1
        let card = SkillProposal(revision: revision, participants: roster, terms: terms, plan: DownForProfile.plan(from: terms, origin: request.conversation, hub: localPeer, member: first))
        guard report(id, .proposalReady(card)) else { return }
        requests[id]?.group = Group(revision: revision, terms: terms, members: members)
        armWindow(id, revision: revision)
    }

    // MARK: - Invitee

    /// A friend invited this phone. The invitation becomes an invitee card,
    /// the only thing a friend's message can create (ARCHITECTURE rule 8);
    /// it never starts a request, asks for a permission, or skips consent.
    func receiveInvitation(_ proposal: Proposal, envelope: Envelope) async {
        let key = RunKey(conversation: envelope.conversation, peer: envelope.sender)
        let now = clock.now()
        guard envelope.mode == .invite, proposal.round == 0, Self.isInvitation(proposal.terms),
              let slot = DownForProfile.slot(of: proposal.terms), DownForProfile.hasNotStarted(slot, now: now),
              runs.values.filter({ $0.key.peer == key.peer && $0.mode == .invite && $0.role == .member }).count < Self.maxInvitationsPerFriend
        else { return }
        if let pairedPeers { guard (try? await pairedPeers.peer(for: key.peer)) ?? nil != nil else { return } }
        // A second copy may have arrived while the store was asked.
        guard runs[key] == nil, finished[key] == nil, await !isRetired(key.conversation) else { return }

        let id = InteractionID()
        let record = DownForRequestRecord(invitation: id, conversation: key.conversation, from: key.peer, until: Timestamp(slot.end), chainedFrom: envelope.chainedFrom)
        let profile = DownForProfile(rules: .empty, inputs: [], expiresAt: slot.end, timeZone: timeZone)
        let mirror = Interaction(id: id, conversation: key.conversation, skill: DownFor.ref, role: .invitee, participants: [key.peer], createdAt: Timestamp(now))
        var request = Request(record: record, profile: profile, mirror: mirror)
        request.engagement = .member(key)
        requests[id] = request
        var run = Run(invitation: key, request: id, role: .member, chainedFrom: envelope.chainedFrom, terms: proposal.terms)
        run.highestRound = proposal.round
        run.proposalEnvelopes = [envelope.id]
        run.offers = [envelope.id: proposal]
        run.lastInbound = envelope.id
        runs[key] = run
        continuation.yield(.incoming(id, conversation: key.conversation, from: key.peer, chainedFrom: envelope.chainedFrom))
        let card = SkillProposal(
            revision: 1, participants: [key.peer, localPeer], terms: proposal.terms,
            plan: DownForProfile.plan(from: proposal.terms, origin: key.conversation, hub: key.peer, member: localPeer)
        )
        report(id, .proposalReady(card))
        armExpiry(id)
        beginStep(key, attemptLimit: silenceLimit, backsOff: true)
    }

    /// An invitation offers a time and an activity, nothing else.
    static func isInvitation(_ terms: Terms) -> Bool {
        Set(terms.values.keys) == [.time, .activity] && DownForProfile.slot(of: terms) != nil
            && DownForProfile.activity(of: terms) != nil
    }

    /// The starter's confirmation of an invitation: the invitation the owner
    /// accepted, plus a roster for a group of three or more.
    static func confirms(_ confirmed: Terms, invitation: Terms) -> Bool {
        var values = confirmed.values
        values[.people] = nil
        return values == invitation.values
    }
}
