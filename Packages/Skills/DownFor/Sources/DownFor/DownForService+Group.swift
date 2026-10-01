import Foundation
import StarlingCore
import StarlingNegotiation

// The starter's side of a group: deciding the plan once every friend has
// answered, re-planning when someone drops out, and confirming once
// everyone said "I'm in" (ADR 0210).

extension DownForService {
    /// The starter's schedule, fixed so that when a friend hears from it
    /// never depends on any other friend (review finding 2, and the final
    /// privacy review's finding 2): a friend whose time check is done is
    /// asked, once, who it could share a plan with at `gatherWindow` after
    /// the starter took the request on, or as soon as it is done if later.
    /// When that check's `vetWindow` ends, every friend is offered its own
    /// plan (`offer(to:in:)`).
    ///
    /// Not while this request is itself answering a lower starter's run:
    /// that group comes first (ADR 0210 decision 5).
    func considerProposing(_ id: InteractionID) {
        guard let request = requests[id], request.invitation == nil, request.engagement == .hub,
              request.group?.confirming == nil, request.mirror.state != .planned, !request.mirror.state.isFinal
        else { return }
        let all = runs.values.filter { $0.request == id }
        guard !all.contains(where: { $0.role == .member && ($0.phase == .psi || $0.phase == .details) }) else { return }
        let fresh = all.filter { $0.role == .hub && $0.phase == .ready && $0.vetCount == 0 }
        guard !fresh.isEmpty else { return checkSettled(id) }
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
        startVetting(fresh, in: id)
    }

    private func quietPassed(_ id: InteractionID) {
        requests[id]?.quiet = nil
        considerProposing(id)
    }

    /// How many times the starter asks one member about the others: once.
    static let maxVettingRounds = 1

    /// Asks each of `ready`, once, which of the others it could share a
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
        let batch = UUID()
        let keys = ready.map(\.key)
        let window = configuration.vetWindow
        requests[id]?.vettings[batch] = Task { [weak self] in
            do { try await Task.sleep(for: window) } catch { return }
            await self?.vettingEnded(id, batch: batch, keys: keys)
        }
    }

    /// A check's window is over: offer every friend its own plan. A friend
    /// whose check did not come back in time is left out.
    private func vettingEnded(_ id: InteractionID, batch: UUID, keys: [RunKey]) {
        guard requests[id]?.vettings.removeValue(forKey: batch) != nil, let request = requests[id],
              request.group?.confirming == nil
        else { return }
        for key in keys where runs[key]?.phase == .vetting { end(key, .withdrawn, react: false) }
        guard offer(to: candidates(in: id), in: id) else {
            if requests[id]?.group != nil { endRequest(id, with: .noAgreement) }
            return checkSettled(id)
        }
    }

    /// Friends checked and still in: waiting for a plan or offered one.
    func candidates(in id: InteractionID) -> [PeerID] {
        runs.values
            .filter { $0.request == id && $0.role == .hub && $0.vetCount > 0 && [.ready, .proposed, .accepted].contains($0.phase) }
            .map(\.key.peer)
    }

    /// The group plan from these friends' answers, or nil.
    private func plan(for peers: [PeerID], including friend: PeerID, in id: InteractionID) -> (terms: Terms, members: [PeerID])? {
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
            including: friend, together: { allowed[$0]?.contains($1) == true }
        ), plan.members.allSatisfy({ request.profile.permits(plan.terms, me: localPeer, hub: localPeer, member: $0, now: clock.now()) })
        else { return nil }
        return plan
    }

    /// Whether two friends each asked the other (the audience check).
    private func mutual(_ a: PeerID, _ b: PeerID, in id: InteractionID) -> Bool {
        guard let conversation = requests[id]?.conversation else { return false }
        return runs[RunKey(conversation: conversation, peer: a)]?.allowed.contains(b) == true
            && runs[RunKey(conversation: conversation, peer: b)]?.allowed.contains(a) == true
    }

    /// Offers every candidate its own plan, and picks the starter's
    /// (final privacy review of PR #56, finding 2).
    ///
    /// A friend's own plan is the plan it would get if the starter knew
    /// only of the friends it shares a mutual audience with: so nothing a
    /// friend is offered depends on anyone outside that, interested or not.
    /// The starter's own plan is one that each of its members would also
    /// get as its own plan, preferring more friends, then the starter's
    /// earlier activity and time. Every other friend with a plan of its own
    /// is offered it all the same, on the same schedule, and the starter
    /// never confirms it: to that friend it is a starter whose owner did
    /// not answer. A friend with no plan even in its own view hears an
    /// ordinary no. Only a friend whose own plan changed gets a new round.
    ///
    /// - Returns: Whether anyone was offered anything.
    @discardableResult
    func offer(to candidates: [PeerID], in id: InteractionID) -> Bool {
        guard let request = requests[id] else { return false }
        var own: [PeerID: (terms: Terms, members: [PeerID])] = [:]
        for friend in candidates {
            let world = [friend] + candidates.filter { $0 != friend && mutual(friend, $0, in: id) }
            if let plan = plan(for: world, including: friend, in: id) { own[friend] = plan }
        }
        for friend in candidates where own[friend] == nil {
            let key = RunKey(conversation: request.conversation, peer: friend)
            if let run = runs[key] { enqueue(.notify(run.notice, .noOverlap), for: friend) }
            stopDelivery(key)
            end(key, .excluded, react: false)
        }
        guard !own.isEmpty else { return false }

        // The starter's plan: one its members all have as their own.
        let consistent = Set(own.values.map(\.terms)).compactMap { terms -> (terms: Terms, members: [PeerID])? in
            guard let plan = own.values.first(where: { $0.terms == terms }),
                  plan.members.allSatisfy({ own[$0]?.terms == terms })
            else { return nil }
            return plan
        }
        let liked = request.profile.liked
        func rank(_ plan: (terms: Terms, members: [PeerID])) -> (Int, Int, Int64, [PeerID]) {
            let activity = DownForProfile.activity(of: plan.terms).flatMap { liked.firstIndex(of: $0) } ?? liked.count
            let start = DownForProfile.slot(of: plan.terms)?.startMinute ?? .max
            return (-plan.members.count, activity, start, plan.members)
        }
        let current = request.group.flatMap { group in consistent.first { $0.terms == group.terms && $0.members == group.members } }
        let chosen = current ?? consistent.min { a, b in
            let (x, y) = (rank(a), rank(b))
            return (x.0, x.1, x.2) != (y.0, y.1, y.2) ? (x.0, x.1, x.2) < (y.0, y.1, y.2) : x.3.lexicographicallyPrecedes(y.3)
        }

        // The starter's card, when its plan changed.
        if let chosen, request.group?.terms != chosen.terms || request.group?.members != chosen.members {
            let revision = (request.mirror.proposalRevision ?? 0) + 1
            guard revision <= UInt32(ProtocolLimits.maxNegotiationRounds), let first = chosen.members.first,
                  let roster = DownForProfile.roster(of: chosen.terms, hub: localPeer, member: first)
            else {
                endRequest(id, with: .noAgreement)
                return true
            }
            let card = SkillProposal(revision: revision, participants: roster, terms: chosen.terms, plan: DownForProfile.plan(from: chosen.terms, origin: request.conversation, hub: localPeer, member: first))
            report(id, .proposalReady(card))
            requests[id]?.group?.window?.cancel()
            requests[id]?.group = Group(revision: revision, terms: chosen.terms, members: chosen.members)
        } else if chosen == nil {
            // Nobody's plan is one the others share: no plan the starter
            // can confirm this time, though every friend is offered its own.
            if requests[id]?.group == nil {
                requests[id]?.group = Group(revision: request.mirror.proposalRevision ?? 0, terms: own.values.first!.terms, members: [])
            } else {
                requests[id]?.group?.members = []
            }
        }

        // Every friend's own plan, a new round only when it changed.
        for (friend, plan) in own {
            let key = RunKey(conversation: request.conversation, peer: friend)
            guard let run = runs[key], run.terms != plan.terms || run.phase == .ready else { continue }
            runs[key]?.terms = plan.terms
            runs[key]?.accepted = false
            runs[key]?.acceptedProposal = nil
            runs[key]?.phase = .proposed
            runs[key]?.proposalEnvelopes = []
            runs[key]?.replies = [:]
            enqueue(.act(key, .propose), for: friend)
        }
        if let revision = requests[id]?.group?.revision { armWindow(id, revision: revision) }
        checkComplete(id)
        return true
    }

    /// A hub run ended without a plan.
    func hubLost(_ peer: PeerID, in id: InteractionID) {
        guard let request = requests[id], request.engagement == .hub else { return }
        guard let group = request.group else {
            considerProposing(id)
            return checkSettled(id)
        }
        if group.confirming != nil {
            // Confirmations are on their way; this one counts as sent.
            if group.members.contains(peer) { confirmationSent(id, to: peer) }
            return
        }
        drop([peer], from: id)
    }

    /// Offers again without `peers`. Friends whose own plan is unchanged
    /// see nothing new; the rest get a new round, and the starter a new
    /// card if its plan changed. Friends who stay in a changed plan must
    /// say I'm in again, since the roster is part of what they agree to.
    private func drop(_ peers: Set<PeerID>, from id: InteractionID) {
        guard let request = requests[id], let group = request.group else { return }
        for peer in peers { stopDelivery(RunKey(conversation: request.conversation, peer: peer)) }
        if request.invitation != nil {
            group.window?.cancel()
            requests[id]?.group = nil
            let remaining = group.members.filter { !peers.contains($0) && runs[RunKey(conversation: request.conversation, peer: $0)] != nil }
            // An invitation's plan does not change; only who is in it does.
            guard !remaining.isEmpty else {
                endRequest(id, with: .noAgreement)
                return
            }
            for peer in remaining { runs[RunKey(conversation: request.conversation, peer: peer)]?.accepted = false }
            return showInvitation(to: remaining, in: id)
        }
        let remaining = candidates(in: id).filter { !peers.contains($0) }
        guard !remaining.isEmpty, offer(to: remaining, in: id) else {
            endRequest(id, with: .noAgreement)
            return
        }
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
        guard !request.passed, !group.members.isEmpty, group.ownerAccepted else {
            endRequest(id, with: request.passed ? .ownerPassed : group.members.isEmpty ? .noAgreement : .expired)
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

    /// A friend said I'm in to the plan it was offered, its own: that
    /// stops the proposal's schedule. It counts towards the starter's plan
    /// only when the friend is in it.
    func handleAccept(_ acceptance: Acceptance, in key: RunKey) {
        guard let run = runs[key], run.role == .hub, run.phase == .proposed, let terms = run.terms, acceptance.terms == terms,
              run.proposalEnvelopes.contains(acceptance.proposal) || acceptsDelivery(acceptance, at: key),
              let request = requests[run.request], request.invitation == nil || request.group == nil
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
        // Friends offered a plan of their own that was not this one keep
        // its schedule: they cannot tell this from a starter who never
        // answered.
        for key in runs.keys where runs[key]?.request == id { end(key, group.members.contains(key.peer) ? .matched : .withdrawn, react: false) }
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
