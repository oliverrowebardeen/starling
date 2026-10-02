import Foundation
import StarlingCore
import StarlingNegotiation

// The starter's side (ADR 0210). A quiet ask is one friend's own
// interaction (ADR 0011 amendment 17): the starter proposes a pair plan
// once that friend's answers are in, and confirms it once both owners
// said I'm in. An invitation keeps its own group of everyone who said
// I'm in (`DownForService+Invite`).

extension DownForService {
    /// The friend's answers are in: show the pair plan on the owner's card
    /// and send it on its fixed schedule. Depends on nothing but this
    /// friend's answers and the owner's own limits.
    func propose(in key: RunKey) {
        guard let run = runs[key], run.role == .hub, run.phase == .ready, let request = requests[run.request],
              request.invitation == nil, request.group == nil, let overlap = run.overlap
        else { return }
        let now = clock.now()
        let answers = CandidateAnswers(overlap: overlap, activities: run.activityAnswer ?? [])
        guard let terms = PairPlanner.plan(liked: request.profile.liked, answers: answers, maxMinutes: configuration.maxPlanMinutes, now: now),
              request.profile.permits(terms, me: localPeer, hub: localPeer, member: key.peer, now: now)
        else {
            enqueue(.notify(run.notice, .noOverlap), for: key.peer)
            return end(key, .noOverlap)
        }
        let revision = (request.mirror.proposalRevision ?? 0) + 1
        let card = SkillProposal(
            revision: revision, participants: [localPeer, key.peer], terms: terms,
            plan: DownForProfile.plan(from: terms, origin: request.conversation, hub: localPeer, member: key.peer)
        )
        guard report(run.request, .proposalReady(card)) else { return }
        requests[run.request]?.group = Group(revision: revision, terms: terms, members: [key.peer])
        runs[key]?.terms = terms
        runs[key]?.accepted = false
        runs[key]?.phase = .proposed
        runs[key]?.proposalEnvelopes = []
        runs[key]?.replies = [:]
        // The proposal's schedule and the card's window start together, so
        // the schedule always ends inside the window, however long the
        // friend's queue takes to send (lane F's #84).
        guard let proposal = try? Proposal(round: run.rounds, terms: terms) else { return }
        runs[key]?.rounds += 1
        startDelivery(proposal, to: key, for: run.request, chainedFrom: run.chainedFrom, mode: run.mode)
        armWindow(run.request, revision: revision)
    }

    /// A starter's run ended without a plan.
    func hubLost(_ peer: PeerID, in id: InteractionID) {
        guard let request = requests[id], request.engagement == .hub else { return }
        guard let group = request.group else { return checkSettled(id) }
        if group.confirming != nil {
            // Confirmations are on their way; this one counts as sent.
            if group.members.contains(peer) { confirmationSent(id, to: peer) }
            return
        }
        drop([peer], from: id)
    }

    /// Goes on without `peers`. An invitation shows its card again for
    /// whoever is left, who must say I'm in again since the roster is part
    /// of what they agree to. A quiet ask's one friend is gone, so it ends;
    /// after a pass, as passed.
    private func drop(_ peers: Set<PeerID>, from id: InteractionID) {
        guard let request = requests[id], let group = request.group else { return }
        for peer in peers { stopDelivery(RunKey(conversation: request.conversation, peer: peer)) }
        guard request.invitation != nil else {
            endRequest(id, with: request.passed ? .ownerPassed : .noAgreement)
            return
        }
        group.window?.cancel()
        requests[id]?.group = nil
        let remaining = group.members.filter { !peers.contains($0) && runs[RunKey(conversation: request.conversation, peer: $0)] != nil }
        // An invitation's plan does not change; only who is in it does.
        guard !remaining.isEmpty else {
            endRequest(id, with: .noAgreement)
            return
        }
        for peer in remaining { runs[RunKey(conversation: request.conversation, peer: peer)]?.accepted = false }
        showInvitation(to: remaining, in: id)
    }

    /// When a proposal's window passes: friends who have not said "I'm in"
    /// are left out, and a starter who has not either lets the plan go.
    func armWindow(_ id: InteractionID, revision: UInt32) {
        let window = configuration.ownerWindow
        requests[id]?.group?.window?.cancel()
        requests[id]?.group?.window = Task { [weak self, clock] in
            do { try await clock.sleep(window) } catch { return }
            await self?.windowPassed(id, revision: revision)
        }
    }

    /// The window is also when the proposal stops going out (its schedule
    /// ends by then), so only now does a starter who passed end its
    /// request, the same moment silence would (ADR 0011 amendment 16).
    /// Friends who have not said I'm in hear nothing: whether the starter
    /// said it is not theirs to learn.
    private func windowPassed(_ id: InteractionID, revision: UInt32) {
        guard let request = requests[id], let group = request.group, group.revision == revision, group.confirming == nil else { return }
        guard !request.passed, group.ownerAccepted else {
            endRequest(id, with: request.passed ? .ownerPassed : .expired)
            return
        }
        let late = group.members.filter { runs[RunKey(conversation: request.conversation, peer: $0)]?.accepted != true }
        guard !late.isEmpty else { return }
        for peer in late {
            let key = RunKey(conversation: request.conversation, peer: peer)
            stopDelivery(key)
            end(key, .timedOut, react: false)
        }
        drop(Set(late), from: id)
    }

    // MARK: - "I'm in"

    func ownerAccepted(_ id: InteractionID) {
        guard let request = requests[id] else { return }
        switch request.engagement {
        case .hub:
            requests[id]?.group?.ownerAccepted = true
            checkComplete(id)
        case .member(let key):
            memberAccepted(id, in: key)
        }
    }

    /// A friend said I'm in to the plan it was offered: that stops the
    /// proposal's schedule.
    func handleAccept(_ acceptance: Acceptance, in key: RunKey) {
        guard let run = runs[key], run.role == .hub, run.phase == .proposed, let terms = run.terms, acceptance.terms == terms,
              run.proposalEnvelopes.contains(acceptance.proposal) || acceptsDelivery(acceptance, at: key), let request = requests[run.request],
              request.invitation != nil ? request.group == nil : request.group?.terms == terms
        else { return }
        stopDelivery(key)
        runs[key]?.accepted = true
        runs[key]?.acceptedProposal = acceptance.proposal
        runs[key]?.phase = .accepted
        if request.invitation != nil { return invitationAccepted(in: run.request) }
        checkComplete(run.request)
    }

    /// Confirms to every member once everyone, the owner included, said
    /// "I'm in" to the current revision. Nobody is in a plan before that.
    func checkComplete(_ id: InteractionID) {
        guard let request = requests[id], var group = request.group, group.ownerAccepted, group.confirming == nil,
              !group.members.isEmpty, request.mirror.state == .confirmed
        else { return }
        let keys = group.members.map { RunKey(conversation: request.conversation, peer: $0) }
        guard keys.allSatisfy({ runs[$0]?.accepted == true }) else { return }
        group.confirming = Set(group.members)
        group.window?.cancel()
        requests[id]?.group = group
        for key in keys {
            // Keyed by what the member accepted, which for an invitation is
            // the invitation without the roster.
            let accepted = runs[key]?.terms ?? group.terms
            runs[key]?.replies[.accept(accepted)] = .confirm(group.terms)
            enqueue(.act(key, .confirm), for: key.peer)
        }
    }

    /// Once every confirmation has been handed to the Outbox, it's a plan.
    /// A confirmation the link lost is replayed when the member's accept
    /// comes again (ADR 0120's lost-confirmation case).
    func confirmationSent(_ id: InteractionID, to peer: PeerID) {
        guard let request = requests[id], var group = request.group, var confirming = group.confirming else { return }
        confirming.remove(peer)
        group.confirming = confirming
        requests[id]?.group = group
        guard confirming.isEmpty, report(id, .everyoneConfirmed(revision: group.revision)) else { return }
        produceArtifacts(id, terms: group.terms, origin: request.conversation, peer: group.members[0])
        for key in runs.keys where runs[key]?.request == id { end(key, .matched) }
        armCleanup(id)
    }

    // MARK: - Nobody up

    /// Ends a request that has heard a definite no from every friend: no
    /// shared time, a refusal, or a card that says it cannot run the skill.
    /// A friend who never answered keeps it open until it expires, since
    /// they may still go down for it.
    func checkSettled(_ id: InteractionID) {
        guard let request = requests[id], request.engagement == .hub, request.group == nil, request.isGathering,
              !runs.values.contains(where: { $0.request == id })
        else { return }
        let participants = Set(request.record.participants)
        guard participants.isSubset(of: request.settled.union(request.unsupported)) else { return }
        if participants.isSubset(of: request.unsupported) {
            endRequest(id, with: .unsupported)
        } else {
            endRequest(id, with: .noAgreement)
        }
    }
}
