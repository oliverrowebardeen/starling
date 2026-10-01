import Foundation
import StarlingCore
import StarlingNegotiation

// The starter's side of a group: deciding the plan once every friend has
// answered, re-planning when someone drops out, and confirming once
// everyone said "I'm in" (ADR 0210).

extension DownForService {
    /// Proposes once no run of the request is still finding time or waiting
    /// for answers, from the answers of every friend who shares time.
    ///
    /// Two rules keep a lower starter's group first (ADR 0210): no proposal
    /// while this request is still answering another starter's run, and
    /// none in the quiet period after the request began, which gives a
    /// lower starter's retries time to arrive.
    func considerProposing(_ id: InteractionID) {
        guard let request = requests[id], request.engagement == .hub, request.group == nil, request.mirror.state == .negotiating else { return }
        let all = runs.values.filter { $0.request == id }
        guard !all.contains(where: { $0.phase == .psi || $0.phase == .details }) else { return }
        let mine = all.filter { $0.role == .hub }
        if mine.contains(where: { $0.phase == .ready }) {
            let quiet = configuration.retryInterval * 2
            let waited = ContinuousClock.now - request.since
            guard waited >= quiet else {
                guard request.quiet == nil else { return }
                requests[id]?.quiet = Task { [weak self] in
                    try? await Task.sleep(for: quiet - waited)
                    await self?.quietPassed(id)
                }
                return
            }
        }
        let ready = mine.filter { $0.phase == .ready }
        guard !ready.isEmpty else { return checkSettled(id) }
        guard let plan = plan(for: ready.map(\.key.peer), in: id) else {
            for run in ready {
                enqueue(.notify(run.notice, .noOverlap), for: run.key.peer)
                end(run.key, .excluded, react: false)
            }
            return checkSettled(id)
        }
        propose(plan.terms, to: plan.members, in: id)
    }

    private func quietPassed(_ id: InteractionID) {
        requests[id]?.quiet = nil
        considerProposing(id)
    }

    /// The group plan from these friends' answers, or nil.
    private func plan(for peers: [PeerID], in id: InteractionID) -> (terms: Terms, members: [PeerID])? {
        guard let request = requests[id] else { return nil }
        var candidates: [PeerID: CandidateAnswers] = [:]
        for peer in peers {
            guard let run = runs[RunKey(conversation: request.conversation, peer: peer)], let overlap = run.overlap else { continue }
            candidates[peer] = CandidateAnswers(overlap: overlap, activities: run.activityAnswer ?? [], budget: run.budgetAnswer)
        }
        guard let plan = GroupPlanner.plan(
            hub: localPeer, liked: request.profile.liked, budgetCap: request.profile.budgetCap,
            candidates: candidates, maxMinutes: configuration.maxPlanMinutes, now: clock.now()
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
        group.window?.cancel()
        requests[id]?.group = nil
        let remaining = group.members.filter { !peers.contains($0) && runs[RunKey(conversation: request.conversation, peer: $0)] != nil }
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
    private func armWindow(_ id: InteractionID, revision: UInt32) {
        let window = configuration.ownerWindow
        requests[id]?.group?.window = Task { [weak self, clock] in
            do { try await clock.sleep(window) } catch { return }
            await self?.windowPassed(id, revision: revision)
        }
    }

    private func windowPassed(_ id: InteractionID, revision: UInt32) {
        guard let request = requests[id], let group = request.group, group.revision == revision, group.confirming == nil else { return }
        guard group.ownerAccepted else {
            endRequest(id, with: .expired)
            return
        }
        let late = group.members.filter { runs[RunKey(conversation: request.conversation, peer: $0)]?.accepted != true }
        guard !late.isEmpty else { return }
        for peer in late {
            let key = RunKey(conversation: request.conversation, peer: peer)
            if let run = runs[key] { enqueue(.notify(run.notice, .expired), for: peer) }
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

    func handleAccept(_ acceptance: Acceptance, in key: RunKey) {
        guard let run = runs[key], run.role == .hub, run.phase == .proposed, let terms = run.terms,
              acceptance.terms == terms, run.proposalEnvelopes.contains(acceptance.proposal),
              requests[run.request]?.group?.terms == terms
        else { return }
        runs[key]?.accepted = true
        runs[key]?.acceptedProposal = acceptance.proposal
        runs[key]?.phase = .accepted
        // Stop resending the proposal. The window bounds the wait from here.
        runs[key]?.outstanding = []
        runs[key]?.timerToken += 1
        timers.removeValue(forKey: key)?.cancel()
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
            runs[key]?.replies[.accept(group.terms)] = .confirm(group.terms)
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
            report(id, .unsupported)
        } else {
            endRequest(id, with: .noAgreement)
        }
    }

    // MARK: - Consent on the lifecycle

    struct ConsentTicket: Sendable {
        let interaction: InteractionID
        let request: UInt32
        let disclosure: Disclosure
    }

    /// The Outbox is about to show a consent sheet for one of this skill's
    /// sends. Suspends the interaction it belongs to, unless the owner
    /// already approved this exact disclosure in it.
    func consentWillStart(_ disclosure: Disclosure) -> ConsentTicket? {
        guard disclosure.skill?.id == DownFor.ref.id, let conversation = disclosure.conversation,
              let id = requests.values.first(where: { $0.conversation == conversation })?.id
                ?? runs[RunKey(conversation: conversation, peer: disclosure.recipient)]?.request,
              let request = requests[id], !request.approved.contains(disclosure)
        else { return nil }
        let number = request.mirror.consentWatermark + 1
        guard report(id, .consentNeeded(request: number)) else { return nil }
        requests[id]?.openConsents[number] = disclosure
        return ConsentTicket(interaction: id, request: number, disclosure: disclosure)
    }

    func consentDidEnd(_ ticket: ConsentTicket, _ outcome: ConsentOutcome) {
        let id = ticket.interaction
        guard requests[id]?.openConsents.removeValue(forKey: ticket.request) != nil else { return }
        switch outcome {
        case .approved:
            requests[id]?.approved.insert(ticket.disclosure)
            guard report(id, .consentGiven(request: ticket.request)) else { return }
            // Work that waited for the sheet: a starter's proposal or its
            // confirmations.
            considerProposing(id)
            checkComplete(id)
        case .declined:
            // "Don't send" ends the request and nothing more leaves for it.
            // The coordinator applies the pass itself.
            endQuietly(id, .ownerPassed)
        }
    }
}
