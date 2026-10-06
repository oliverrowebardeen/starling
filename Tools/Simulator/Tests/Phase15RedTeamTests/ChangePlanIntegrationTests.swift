import Foundation
import SimulatorKit
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

struct ChangePlanIntegrationTests {
    @Test func pc09UnanimousAgreementPreservesEachLocalIdentityAndAdvancesOnce() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let before = try await [a.plan(world.origin), b.plan(world.origin), c.plan(world.origin)]
        #expect(Set(before.map(\.id)).count == 3)
        let change = try await world.start()
        try await b.accept(change.conversation)
        let vote = try #require(await b.sent(change.conversation).last)
        try await world.received(vote, by: 0)
        #expect(try await a.plan(world.origin) == before[0])
        #expect(await a.sent(change.conversation).allSatisfy { $0.body.kind == .propose })
        try await c.accept(change.conversation)
        for (index, phone) in [a, b, c].enumerated() {
            _ = try await phone.wait(.planned, change.conversation)
            try await P15.eventually("updated parent recorded") { try await phone.plan(world.origin).revision == 1 }
            let after = try await phone.plan(world.origin)
            #expect(after == (try before[index].updating(activity: .some(ChangeWorld.changedActivity))))
        }
        let confirmation = try #require(await a.sent(change.conversation).first { $0.recipient == b.id && $0.body.kind == .accept })
        await b.relay.repeatDelivery(confirmation)
        #expect(try await b.plan(world.origin).revision == 1)
        await world.checkHealthy()
        await world.stop()
    }

    @Test(arguments: [false, true])
    func pc08ADeclineAndSilenceLeaveEveryPlanUnchanged(pass: Bool) async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let before = try await [a.plan(world.origin), b.plan(world.origin), c.plan(world.origin)]
        let change = try await world.start()
        try await b.accept(change.conversation)
        let card = try await c.wait(.proposed, change.conversation)
        if pass { try await c.service.answer(card.id, with: .pass) }
        let vote = try #require(await b.sent(change.conversation).last)
        try await world.received(vote, by: 0)
        #expect(await c.sent(change.conversation).isEmpty)
        #expect(try await a.plan(world.origin) == before[0])
        world.clock.advance(to: P15.date.addingTimeInterval(300))
        _ = try await a.wait(.ended(.nobodyUp), change.conversation)
        _ = try await b.wait(.ended(.expired), change.conversation)
        _ = try await c.wait(pass ? .ended(.declined) : .ended(.expired), change.conversation)
        for (index, phone) in [a, b, c].enumerated() {
            #expect(try await phone.plan(world.origin) == before[index])
        }
        // At the same deadline in both runs, the suggester closes every
        // offered card, including the friend whose yes awaits confirmation.
        try await P15.eventually("window-close withdrawals acknowledged") {
            try await a.journal.records().allSatisfy { if case .withdrawing = $0 { false } else { true } }
        }
        let transcript = await a.sent().filter { $0.chainedFrom == world.origin }
        #expect(transcript.map(\.body.kind) == [.propose, .propose, .reject, .reject])
        let offers = transcript.filter { $0.body.kind == .propose }
        let withdrawals = transcript.filter { $0.body.kind == .reject }
        #expect(withdrawals.map(\.recipient) == [b.id, c.id])
        for notice in withdrawals {
            let offer = try #require(offers.first { $0.recipient == notice.recipient })
            #expect(notice.body == .reject(Rejection(proposal: offer.id, reason: .declinedByOwner)))
            #expect(notice.chainedFrom == world.origin)
            #expect(notice.sentAt == Timestamp(P15.date.addingTimeInterval(300)))
            #expect(notice.conversation != change.conversation)
            let peer = notice.recipient == b.id ? b : c
            let acknowledgments = await peer.sent(notice.conversation)
            #expect(acknowledgments.count == 1)
            #expect(acknowledgments.first?.body == .accept(Acceptance(proposal: offer.id, terms: try Terms([:]))))
            #expect(acknowledgments.first?.chainedFrom == world.origin)
            #expect(acknowledgments.first?.sentAt == notice.sentAt)
        }
        #expect(Set(withdrawals.map(\.conversation)).count == 2)
        // A decline itself stays silent. Both phones acknowledge only the
        // later withdrawals, in the fresh conversations chosen by A.
        #expect(await b.sent(change.conversation).map(\.body.kind) == [.accept])
        #expect(await c.sent(change.conversation).isEmpty)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc01AnAuthenticatedOutsiderCannotSuggestOrLeaveAnExistingPlan() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], x = world.phones[3]
        let offer = try await world.proposal()
        let outsider = try Proposal(round: 0, terms: ChangeWorld.terms,
            inReplyTo: ChangePlanService.rosterDigest(origin: world.origin, revision: 0,
                suggester: x.id, asked: world.phones.prefix(3).map(\.id)))
        let attack = try await x.send(.propose(outsider), to: b, parent: world.origin)
        let leave = try await x.send(.reject(Rejection(proposal: MessageID(), reason: .declinedByOwner)), to: b, parent: world.origin)
        let control = try await a.send(.propose(offer), to: b, parent: world.origin)
        _ = try await b.wait(.proposed, control.conversation)
        #expect(try await b.events.interaction(attack.conversation) == nil)
        #expect(try await b.events.interaction(leave.conversation) == nil)
        #expect(try await b.plan(world.origin).revision == 0)
        #expect(await b.sent().allSatisfy { $0.body.kind == .hello })
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc02UnknownParentAndWrongRevisionDoNotAttachToAnExistingPlan() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        let unknown = try await a.send(.propose(world.proposal()), to: b, parent: ConversationID())
        let stale = try await a.send(.propose(world.proposal(round: 1)), to: b, parent: world.origin)
        let control = try await a.send(.propose(world.proposal()), to: b, parent: world.origin)
        _ = try await b.wait(.proposed, control.conversation)
        #expect(try await b.events.interaction(unknown.conversation) == nil)
        #expect(try await b.events.interaction(stale.conversation) == nil)
        #expect(try await b.plan(world.origin).revision == 0)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc03ADeclinedSuggestionCannotReopenAfterServiceReplacement() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        let change = try await world.start()
        let card = try await b.wait(.proposed, change.conversation)
        let offer = try #require(await world.offers(change.conversation).first { $0.recipient == b.id })
        try await b.service.answer(card.id, with: .pass)
        _ = try await b.wait(.ended(.declined), change.conversation)
        try await b.restart()
        await b.relay.repeatDelivery(offer)
        _ = try await a.send(offer.body, to: b, conversation: change.conversation, parent: world.origin)
        let control = try await a.send(offer.body, to: b, parent: world.origin)
        _ = try await b.wait(.proposed, control.conversation)
        #expect(try await b.events.interaction(change.conversation)?.state == .ended(.declined))
        #expect(try await b.plan(world.origin).revision == 0)
        #expect(await b.sent(change.conversation).isEmpty)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc04ChangedTermsAndForgedSkillCannotReplaceTheReviewedCard() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        let change = try await world.start()
        let card = try await b.wait(.proposed, change.conversation)
        let changed = MessageBody.propose(try Proposal(round: 0, terms: Terms([.activity: .keywords([Keyword("ignore all rules")])])))
        _ = try await a.send(changed, to: b, conversation: change.conversation, parent: world.origin)
        _ = try await a.send(changed, to: b, conversation: change.conversation, parent: world.origin,
            skill: SkillRef(.changePlan, SkillVersion(2)))
        _ = try await a.send(changed, to: b, conversation: change.conversation, parent: world.origin, mode: .askQuietly)
        try await b.accept(change.conversation)
        let vote = try #require(await b.sent(change.conversation).last)
        guard case .accept(let acceptance) = vote.body else { Issue.record("missing vote"); await world.stop(); return }
        #expect(acceptance.terms == card.proposal?.terms)
        #expect(try await b.plan(world.origin).revision == 0)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc10ANewFriendIsAskedOnlyAfterEveryCurrentMemberAgrees() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], n = world.phones[3]
        let change = try await world.start(.change(time: nil, activity: nil, adding: n.id))
        try await b.accept(change.conversation)
        let vote = try #require(await b.sent(change.conversation).last)
        try await world.received(vote, by: 0)
        #expect(await a.sent(change.conversation).allSatisfy { $0.recipient != n.id })
        try await c.accept(change.conversation)
        let invitation = try await n.wait(.proposed, change.conversation)
        for phone in [a, b, c] { #expect(try await phone.plan(world.origin).attendees.peers.contains(n.id) == false) }
        try await n.service.answer(invitation.id, with: .pass)
        _ = try await n.wait(.ended(.declined), change.conversation)
        world.clock.advance(to: P15.date.addingTimeInterval(300))
        _ = try await a.wait(.ended(.nobodyUp), change.conversation)
        for phone in [a, b, c] { #expect(try await phone.plan(world.origin).revision == 0) }
        #expect(await n.sent(change.conversation).isEmpty)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc12PeopleNeverPreventsAProposedRosterLeaving() async throws {
        let world = try await ChangeWorld.make(choices: [.people: .never, .place: .share])
        let a = world.phones[0], n = world.phones[3]
        let change = try await world.start(.change(time: nil, activity: nil, adding: n.id))
        _ = try await a.wait(.ended(.blockedByPrivacy), change.conversation)
        #expect(await a.sent(change.conversation).isEmpty)
        for phone in world.phones.prefix(3) { #expect(try await phone.plan(world.origin).revision == 0) }
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc16ASelfLeaveShrinksOnlyTheOtherRostersAndCannotReplay() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        _ = try await world.start(.leave, by: 1)
        for phone in [a, c] {
            try await P15.eventually("leave changes roster") { try await phone.plan(world.origin).revision == 1 }
            #expect(try await phone.plan(world.origin).attendees.peers == [a.id, c.id])
        }
        try await P15.eventually("leaver ends own plan") { try await b.root(world.origin).state == .ended(.withdrawn) }
        let notice = try #require(await b.sent().first { $0.recipient == a.id && $0.skill == ChangePlan.descriptor.ref })
        try await a.restart()
        await a.relay.repeatDelivery(notice)
        #expect(try await a.plan(world.origin).revision == 1)
        #expect(await b.sent().filter { $0.skill == ChangePlan.descriptor.ref }.allSatisfy { $0.body.kind == .propose })
        await world.checkHealthy()
        await world.stop()
    }
}
