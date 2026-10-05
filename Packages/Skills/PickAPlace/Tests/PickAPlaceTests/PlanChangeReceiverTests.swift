import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// A friend's phone checks a change of place against its own copy of the
/// plan, whatever the organizer sends (review of #118, findings 2 and 3).
/// Mallory organizes by hand, so her messages can be anything.
@Suite("A friend's checks on a place change", .serialized)
struct PlanChangeReceiverTests {
    func mallorysGroup() async throws -> (Group, mallory: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let jake = Phone("Jake", hub: hub, maps: maps)
        return (try await Group([mallory, maya, jake], hub: hub), mallory, maya, jake)
    }

    /// A plan for the three of them, at Tea Lab when `placed`, held on
    /// Maya's phone.
    func plan(_ people: [Phone], placed: Bool, heldBy holder: Phone) async throws -> Plan {
        let plan = try Plan(origin: ConversationID(), attendees: Attendees(people.map(\.id)), activity: kw("boba"), time: nil)
        let held = placed ? try plan.updating(place: .some(Venues.teaLab.choice)) : plan
        await holder.plans.hold(held)
        return held
    }

    @discardableResult
    func send(_ body: MessageBody, from sender: Phone, to recipient: Phone, in conversation: ConversationID,
              chainedFrom: ConversationID?) async throws -> Envelope {
        try await sender.outbox.send(body, to: recipient.id, conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite,
                                     chainedFrom: chainedFrom)
    }

    func terms(_ roster: [Phone]) throws -> Terms {
        try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers(roster.map(\.id)), .activity: .keywords([kw("boba")])])
    }

    /// Mallory asks Maya about Boba Guys, and waits for Maya's list.
    func ask(_ maya: Phone, from mallory: Phone, in conversation: ConversationID, chainedFrom: ConversationID?, _ group: Group) async throws {
        try await send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), from: mallory, to: maya,
                       in: conversation, chainedFrom: chainedFrom)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.conversation == conversation && $0.body.kind == .answer } })
    }

    /// Whether `phone` has said yes naming the proposal sent as `offer`.
    func saidYes(by phone: Phone, to offer: Envelope, _ group: Group) async -> Bool {
        await group.wire.sent(by: phone.id).contains {
            if case .accept(let acceptance) = $0.body { acceptance.proposal == offer.id } else { false }
        }
    }

    /// Finding 2: the plan is Mallory, Maya, and Jake, at Tea Lab, revision
    /// 1. Maya is shown only a proposal to all three over revision 1, is
    /// confirmed only with all three, and keeps all three afterwards.
    @Test func aChangeOfPlaceNeedsTheWholePlanOnEveryPhone() async throws {
        let (group, mallory, maya, jake) = try await mallorysGroup()
        defer { Task { await group.stop() } }
        let plan = try await plan([mallory, maya, jake], placed: true, heldBy: maya)
        let conversation = ConversationID()
        try await ask(maya, from: mallory, in: conversation, chainedFrom: plan.origin, group)
        #expect(await maya.service.invites[conversation]?.isChange == true)

        // Without Jake, or over another revision: no card.
        try await send(.propose(Proposal(round: 2, terms: terms([mallory, maya]))), from: mallory, to: maya, in: conversation, chainedFrom: plan.origin)
        try await send(.propose(Proposal(round: 3, terms: terms([mallory, maya, jake]))), from: mallory, to: maya, in: conversation,
                       chainedFrom: plan.origin)
        // Round 2, review of #118: a change of place carries the plan's own
        // time and activity, and no other.
        var otherActivity = try terms([mallory, maya, jake]).values
        otherActivity[.activity] = .keywords([kw("karaoke")])
        try await send(.propose(Proposal(round: 2, terms: Terms(otherActivity))), from: mallory, to: maya, in: conversation, chainedFrom: plan.origin)
        var addedTime = try terms([mallory, maya, jake]).values
        addedTime[.time] = .slots([try TimeSlot(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600))])
        try await send(.propose(Proposal(round: 2, terms: Terms(addedTime))), from: mallory, to: maya, in: conversation, chainedFrom: plan.origin)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.interaction(conversation)?.proposal == nil)

        // The whole plan over revision 1 is shown, and names revision 2.
        let everyone = try terms([mallory, maya, jake])
        let offer = try await send(.propose(Proposal(round: 2, terms: everyone)), from: mallory, to: maya, in: conversation,
                                   chainedFrom: plan.origin)
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await maya.interaction(conversation)?.proposal?.plan?.revision == 2)
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        // A confirmation without Jake is not a plan.
        var shorter = everyone.values
        shorter[.people] = .peers([mallory.id, maya.id])
        try await send(.accept(Acceptance(proposal: offer.id, terms: Terms(shorter))), from: mallory, to: maya, in: conversation,
                       chainedFrom: plan.origin)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.state(in: conversation) == .confirmed)

        try await send(.accept(Acceptance(proposal: offer.id, terms: everyone)), from: mallory, to: maya, in: conversation, chainedFrom: plan.origin)
        #expect(await maya.reaches(.planned, in: conversation))

        // Afterwards, a shorter roster and a call-off change nothing.
        try await send(.accept(Acceptance(proposal: offer.id, terms: Terms(shorter))), from: mallory, to: maya, in: conversation,
                       chainedFrom: plan.origin)
        try await send(.reject(Rejection(proposal: offer.id, reason: .noOverlap)), from: mallory, to: maya, in: conversation, chainedFrom: plan.origin)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.state(in: conversation) == .planned)
        #expect(await eventually { await maya.attendees(in: conversation) == [mallory.id, maya.id, jake.id] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// A plan's first place still narrows (ADR 0240, #66): Maya's plan has
    /// no place yet, and a confirmation without Jake is her plan.
    @Test func aPlansFirstPlaceStillTakesWhoeverAgreed() async throws {
        let (group, mallory, maya, jake) = try await mallorysGroup()
        defer { Task { await group.stop() } }
        let plan = try await plan([mallory, maya, jake], placed: false, heldBy: maya)
        let conversation = ConversationID()
        try await ask(maya, from: mallory, in: conversation, chainedFrom: plan.origin, group)
        #expect(await maya.service.invites[conversation]?.kind == .firstPlace)

        let everyone = try terms([mallory, maya, jake])
        let offer = try await send(.propose(Proposal(round: 1, terms: everyone)), from: mallory, to: maya, in: conversation,
                                   chainedFrom: plan.origin)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        var shorter = everyone.values
        shorter[.people] = .peers([mallory.id, maya.id])
        try await send(.accept(Acceptance(proposal: offer.id, terms: Terms(shorter))), from: mallory, to: maya, in: conversation,
                       chainedFrom: plan.origin)
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await eventually { await maya.attendees(in: conversation) == [mallory.id, maya.id] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// Finding 3: the same terms at another revision are a new proposal.
    /// Maya's yes to the first is not repeated for the second, which needs
    /// her to decide again; and after a restart, a retry of the proposal
    /// she said yes to is still recognized as one.
    @Test func aNewRevisionNeedsAFreshYes() async throws {
        let (group, mallory, maya, _) = try await mallorysGroup()
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await ask(maya, from: mallory, in: conversation, chainedFrom: nil, group)
        let roster = try terms([mallory, maya])

        let first = try await send(.propose(Proposal(round: 0, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        #expect(await eventually { await saidYes(by: maya, to: first, group) })

        // A retry: Maya says yes to it again.
        let retry = try await send(.propose(Proposal(round: 0, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await eventually { await saidYes(by: maya, to: retry, group) })

        // The same terms at a new revision: a new card, and no yes to it
        // until Maya taps.
        let newer = try await send(.propose(Proposal(round: 1, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await maya.interaction(conversation)?.proposalRevision == 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !saidYes(by: maya, to: newer, group))

        // Maya says yes to it, and her app restarts. A retry of it is still
        // a retry: she says yes again without being asked.
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        #expect(await eventually { await saidYes(by: maya, to: newer, group) })
        await maya.restart()
        let again = try await send(.propose(Proposal(round: 1, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await eventually { await saidYes(by: maya, to: again, group) })
        #expect(await maya.state(in: conversation) == .confirmed)
        #expect(await group.lifecyclesWereLegal())
    }

    /// Round 2, item 1: a confirmation must confirm this phone's own yes.
    /// Maya says yes to the same terms at round 0 and then round 1. A
    /// delayed confirmation naming the round 0 proposal, or any other, does
    /// not make the round 1 card a plan, before or after a restart; one
    /// naming the proposal her latest yes named does.
    @Test func aConfirmationMustNameTheProposalTheYesNamed() async throws {
        let (group, mallory, maya, _) = try await mallorysGroup()
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await ask(maya, from: mallory, in: conversation, chainedFrom: nil, group)
        let roster = try terms([mallory, maya])

        let old = try await send(.propose(Proposal(round: 0, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        let newer = try await send(.propose(Proposal(round: 1, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        for named in [old.id, MessageID()] {
            try await send(.accept(Acceptance(proposal: named, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.state(in: conversation) == .confirmed)

        // The proposals her yes named survive a restart.
        await maya.restart()
        try await send(.accept(Acceptance(proposal: old.id, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.state(in: conversation) == .confirmed)
        try await send(.accept(Acceptance(proposal: newer.id, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    /// Round 2, item 3: a chained request naming a plan Maya's phone does
    /// not hold changes no plan there. Her agreed plan is her own, at
    /// revision 0, which applies over no plan's revision. Holding the
    /// plan, the same request's agreed plan names it.
    @Test func aRequestOnAPlanThisPhoneDoesNotHoldChangesNoPlan() async throws {
        let (group, mallory, maya, jake) = try await mallorysGroup()
        defer { Task { await group.stop() } }
        let plan = try Plan(origin: ConversationID(), attendees: Attendees([mallory.id, maya.id, jake.id]), activity: kw("boba"), time: nil)

        let unheld = ConversationID()
        try await ask(maya, from: mallory, in: unheld, chainedFrom: plan.origin, group)
        #expect(await maya.service.invites[unheld]?.kind == .planNotHeld)
        try await send(.propose(Proposal(round: 1, terms: terms([mallory, maya, jake]))), from: mallory, to: maya, in: unheld, chainedFrom: plan.origin)
        #expect(await maya.reaches(.proposed, in: unheld))
        let card = try #require(await maya.interaction(unheld)?.proposal?.plan)
        #expect(card.origin == unheld && card.revision == 0)

        await maya.plans.hold(plan)
        let held = ConversationID()
        try await ask(maya, from: mallory, in: held, chainedFrom: plan.origin, group)
        try await send(.propose(Proposal(round: 1, terms: terms([mallory, maya, jake]))), from: mallory, to: maya, in: held, chainedFrom: plan.origin)
        #expect(await maya.reaches(.proposed, in: held))
        let linked = try #require(await maya.interaction(held)?.proposal?.plan)
        #expect(linked.origin == plan.origin && linked.revision == 1)
        #expect(await group.lifecyclesWereLegal())
    }
}
