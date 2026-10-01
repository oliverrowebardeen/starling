import Foundation
import StarlingCore
import StarlingNegotiation

// The starter's side of a group: deciding the plan once every friend has
// answered, re-planning when someone drops out, and confirming once
// everyone said "I'm in" (ADR 0210).

extension DownForService {
    /// The starter's schedule, fixed so that when a friend hears from it
    /// never depends on any other friend (review finding 2): gather until
    /// `gatherWindow` after taking the request on, then check, with every
    /// ready member at once and exactly once, who may share a plan; then
    /// propose when `vetWindow` ends, with whoever answered. A friend still
    /// finding time or answering when the gathering ends is left out.
    ///
    /// Not while this request is itself answering a lower starter's run:
    /// that group comes first (ADR 0210 decision 5).
    func considerProposing(_ id: InteractionID) {
        guard let request = requests[id], request.invitation == nil, request.engagement == .hub, request.group == nil,
              request.vetting == nil, request.mirror.state == .negotiating
        else { return }
        let all = runs.values.filter { $0.request == id }
        guard !all.contains(where: { $0.role == .member && ($0.phase == .psi || $0.phase == .details) }) else { return }
        let mine = all.filter { $0.role == .hub }
        let ready = mine.filter { $0.phase == .ready }
        guard !ready.isEmpty else { return checkSettled(id) }
        let waited = ContinuousClock.now - request.since
        guard waited >= configuration.gatherWindow else {
            guard request.quiet == nil else { return }
            let rest = configuration.gatherWindow - waited
            requests[id]?.quiet = Task { [weak self] in
                try? await Task.sleep(for: rest)
                await self?.quietPassed(id)
            }
            return
        }
        for run in mine where run.phase == .psi || run.phase == .details { end(run.key, .withdrawn, react: false) }
        startVetting(ready, in: id)
    }

    private func quietPassed(_ id: InteractionID) {
        requests[id]?.quiet = nil
        considerProposing(id)
    }

    /// How many times the starter asks one member about the others: once.
    static let maxVettingRounds = 1

    /// Asks every ready member, once, which of the others it could share a
    /// plan with its own request includes: those with the same half-hour
    /// and an activity both accept. A member with nobody to ask about gets
    /// the same check, padded, so the check itself says nothing.
    private func startVetting(_ ready: [Run], in id: InteractionID) {
        for run in ready {
            let others = ready.filter { other in
                other.key.peer != run.key.peer && !Set(other.overlap ?? []).isDisjoint(with: run.overlap ?? [])
                    && !Set(other.activityAnswer ?? []).isDisjoint(with: run.activityAnswer ?? [])
            }.map(\.key.peer)
            runs[run.key]?.phase = .vetting
            runs[run.key]?.vetCount += 1
            enqueue(.act(run.key, .vet(others.sorted())), for: run.key.peer)
        }
        let window = configuration.vetWindow
        requests[id]?.vetting = Task { [weak self] in
            try? await Task.sleep(for: window)
            await self?.vettingEnded(id)
        }
    }

    /// The check's window is over: propose to whoever answered it.
    private func vettingEnded(_ id: InteractionID) {
        guard let request = requests[id], request.group == nil, request.mirror.state == .negotiating else { return }
        let mine = runs.values.filter { $0.request == id && $0.role == .hub }
        let vetted = mine.filter { $0.phase == .ready && $0.vetCount > 0 }
        for run in mine where !(run.phase == .ready && run.vetCount > 0) { end(run.key, .withdrawn, react: false) }
        guard let plan = plan(for: vetted.map(\.key.peer), in: id) else {
            for run in vetted {
                enqueue(.notify(run.notice, .noOverlap), for: run.key.peer)
                end(run.key, .excluded, react: false)
            }
            // Gather again from now: friends who join later get a fresh,
            // equally fixed schedule.
            requests[id]?.vetting = nil
            requests[id]?.since = ContinuousClock.now
            return checkSettled(id)
        }
        requests[id]?.vetting = nil
        propose(plan.terms, to: plan.members, in: id)
    }

    /// The group plan from these friends' answers, or nil.
    private func plan(for peers: [PeerID], in id: InteractionID) -> (terms: Terms, members: [PeerID])? {
        guard let request = requests[id] else { return nil }
        var candidates: [PeerID: CandidateAnswers] = [:]
        for peer in peers {
            guard let run = runs[RunKey(conversation: request.conversation, peer: peer)], let overlap = run.overlap else { continue }
            candidates[peer] = CandidateAnswers(overlap: overlap, activities: run.activityAnswer ?? [])
        }
        let conversation = request.conversation
        let allowed = Dictionary(uniqueKeysWithValues: peers.map { ($0, runs[RunKey(conversation: conversation, peer: $0)]?.allowed ?? []) })
        guard let plan = GroupPlanner.plan(
            hub: localPeer, liked: request.profile.liked,
            candidates: candidates, maxMinutes: configuration.maxPlanMinutes, now: clock.now(),
            together: { allowed[$0]?.contains($1) == true }
        ), plan.members.allSatisfy({ request.profile.permits(plan.terms, me: localPeer, hub: localPeer, member: $0, now: clock.now()) })
        else { return nil }
        return plan
    }

    /// Shows `terms` on the owner's card as the next revision, sends them to
    /// every member, and tells friends left out "no plan".
    private func propose(_ terms: Terms, to members: [PeerID], in id: InteractionID) {
        guard let request = requests[id], let first = members.first,
              let roster = DownForProfile.roster(of: terms, hub: localPeer, member: first)
        else { return }
        let revision = (request.mirror.proposalRevision ?? 0) + 1
        // A proposal round is bounded on the wire; so are re-plans.
        guard revision <= UInt32(ProtocolLimits.maxNegotiationRounds) else {
            endRequest(id, with: .noAgreement)
            return
        }
        let card = SkillProposal(revision: revision, participants: roster, terms: terms, plan: DownForProfile.plan(from: terms, origin: request.conversation, hub: localPeer, member: first))
        // Behind a consent sheet the card cannot show yet; this runs again
        // once the sheet is answered.
        guard report(id, .proposalReady(card)) else { return }
        requests[id]?.group = Group(revision: revision, terms: terms, members: members)
        for run in runs.values where run.request == id && run.role == .hub {
            if members.contains(run.key.peer) {
                runs[run.key]?.terms = terms
                runs[run.key]?.accepted = false
                runs[run.key]?.phase = .proposed
                runs[run.key]?.proposalEnvelopes = []
                runs[run.key]?.replies = [:]
                enqueue(.act(run.key, .propose), for: run.key.peer)
            } else {
                enqueue(.notify(run.notice, .noOverlap), for: run.key.peer)
                end(run.key, .excluded, react: false)
            }
        }
        armWindow(id, revision: revision)
    }

    /// A hub run ended without a plan.
    func hubLost(_ peer: PeerID, in id: InteractionID) {
        guard let request = requests[id], request.engagement == .hub else { return }
        guard let group = request.group else {
            considerProposing(id)
            return checkSettled(id)
        }
        guard group.members.contains(peer) else { return }
        if group.confirming != nil {
            // Confirmations are on their way; this one counts as sent.
            return confirmationSent(id, to: peer)
        }
        drop([peer], from: id)
    }

    /// Re-plans without `peers`: a new revision for whoever is left, or no
    /// plan. Friends who stay must say "I'm in" again, since the roster is
    /// part of what they agree to.
    private func drop(_ peers: Set<PeerID>, from id: InteractionID) {
        guard let request = requests[id], let group = request.group else { return }
        for peer in peers { stopDelivery(RunKey(conversation: request.conversation, peer: peer)) }
        group.window?.cancel()
        requests[id]?.group = nil
        let remaining = group.members.filter { !peers.contains($0) && runs[RunKey(conversation: request.conversation, peer: $0)] != nil }
        if request.invitation != nil {
            // An invitation's plan does not change; only who is in it does.
            guard !remaining.isEmpty else {
                endRequest(id, with: .noAgreement)
                return
            }
            for peer in remaining { runs[RunKey(conversation: request.conversation, peer: peer)]?.accepted = false }
            return showInvitation(to: remaining, in: id)
        }
        for peer in remaining { runs[RunKey(conversation: request.conversation, peer: peer)]?.phase = .ready }
        guard let plan = plan(for: remaining, in: id) else {
            endRequest(id, with: .noAgreement)
            return
        }
        let before = requests[id]?.mirror.proposalRevision
        propose(plan.terms, to: plan.members, in: id)
        // Could not show the new card (a consent sheet is up): nobody is up
        // for the old one any more.
        if requests[id]?.mirror.proposalRevision == before { endRequest(id, with: .noAgreement) }
    }

    /// When a proposal's window passes: friends who have not said "I'm in"
    /// are left out, and a starter who has not either lets the group go.
    func armWindow(_ id: InteractionID, revision: UInt32) {
        let window = configuration.ownerWindow
        requests[id]?.group?.window?.cancel()
        requests[id]?.group?.window = Task { [weak self, clock] in
            do { try await clock.sleep(window) } catch { return }
            await self?.windowPassed(id, revision: revision)
        }
    }

    /// The window is also when proposals stop going out (their schedule
    /// ends by then), so only now does a starter who passed end its
    /// request, the same moment silence would (final privacy review,
    /// finding 1). Friends who have not said I'm in hear nothing: whether
    /// the starter said it is not theirs to learn.
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
              request.mirror.state == .confirmed
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
    /// shared time, a pass, or a card that says it cannot run the skill.
    /// Friends who never answered keep it open until it expires, since they
    /// may still go down for it.
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
