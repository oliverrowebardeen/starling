import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

struct ChangePlanPrivacyTests {
    @Test func pc12AnAddedRosterIsAuditedOnlyUnderPeopleOnItsOwnInteraction() async throws {
        let world = try await ChangeWorld.make(choices: [.people: .askMe, .place: .share])
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], n = world.phones[3]
        let change = try await world.start(.change(time: nil, activity: nil, adding: n.id))
        try await b.accept(change.conversation)
        try await c.accept(change.conversation)
        try await n.accept(change.conversation)
        for phone in [a, b, c, n] { _ = try await phone.wait(.planned, change.conversation) }
        let records = await a.observer.records.filter { $0.envelope.conversation == change.conversation }
        let offers = records.filter { $0.envelope.body.kind == .propose }
        #expect(offers.count == 3)
        for record in offers {
            #expect(record.context.interaction == change.id)
            let disclosed = try #require(record.disclosed)
            let people = disclosed.filter { $0.issue == .people }
            #expect(people.count == 1)
            #expect(people.first?.value == .peers([a.id, b.id, c.id, n.id]))
            #expect(disclosed.filter { $0.issue != .people }.allSatisfy {
                if case .peers = $0.value { return false }
                return true
            })
        }
        for phone in [a, b, c] {
            try await P15.eventually("addition stored") { try await phone.plan(world.origin).revision == 1 }
            #expect(try await phone.plan(world.origin).attendees.peers == [a.id, b.id, c.id, n.id])
        }
        try await n.waitRevision(1, origin: world.origin)
        let joined = try #require(try await n.events.interaction(change.conversation)?.plan)
        #expect(joined.origin == world.origin && joined.revision == 1)
        #expect(joined.attendees.peers == [a.id, b.id, c.id, n.id])
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc13ExactRosterAcceptanceUnderNeverNeedsNoFreshTopicSheet() async throws {
        let world = try await ChangeWorld.make(inviteesNever: true)
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], n = world.phones[3]
        let change = try await world.start(.change(time: nil, activity: nil, adding: n.id))
        try await b.accept(change.conversation)
        try await c.accept(change.conversation)
        try await n.accept(change.conversation)
        for phone in [a, b, c, n] { _ = try await phone.wait(.planned, change.conversation) }
        for phone in [b, c, n] {
            let consent = try #require(phone.consent as? ScriptedConsentProvider)
            #expect(await consent.requests.isEmpty)
            let vote = try #require(await phone.observer.records.first {
                $0.envelope.conversation == change.conversation && $0.envelope.body.kind == .accept
            })
            guard case .accept(let accepted) = vote.envelope.body else { continue }
            #expect(vote.context.accepting?.isAcceptedAsOffered(by: accepted) == true)
        }
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc16LeavingDoesNotAskForAValueDisclosure() async throws {
        let world = try await ChangeWorld.make()
        let b = world.phones[1]
        let leave = try await world.start(.leave, by: 1)
        _ = try await b.wait(.ended(.withdrawn), leave.conversation)
        let consent = try #require(b.consent as? ScriptedConsentProvider)
        #expect(await consent.requests.isEmpty)
        let records = await b.observer.records.filter { $0.context.interaction == leave.id }
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.disclosed?.isEmpty == true })
        await world.checkHealthy()
        await world.stop()
    }
}

extension ChangePlanPrivacyTests {
    @Test func pc14ANewFriendCanSuggestTheNextChangeWithinTheUpdatedRoster() async throws {
        let world = try await ChangeWorld.make(extras: 2)
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], n = world.phones[3], x = world.phones[4]
        let addition = try await world.start(.change(time: nil, activity: nil, adding: n.id))
        for phone in [b, c, n] { try await phone.accept(addition.conversation) }
        for phone in [a, b, c, n] { try await phone.waitRevision(1, origin: world.origin) }
        let next = try await world.start(by: 3)
        #expect(Set(next.participants) == Set([a.id, b.id, c.id]))
        for phone in [a, b, c] { try await phone.accept(next.conversation) }
        for phone in [a, b, c, n] { try await phone.waitRevision(2, origin: world.origin) }
        #expect(await n.sent(next.conversation).allSatisfy { $0.recipient != x.id && $0.chainedFrom == world.origin })
        #expect(await x.agent.received.allSatisfy { $0.conversation != next.conversation })
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc17LeavingWhileANewFriendDecidesDoesNotRestoreTheOldRoster() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], n = world.phones[3]
        let addition = try await world.start(.change(time: nil, activity: nil, adding: n.id))
        try await b.accept(addition.conversation)
        try await c.accept(addition.conversation)
        let invitation = try await n.wait(.proposed, addition.conversation)
        _ = try await world.start(.leave, by: 1)
        _ = try await n.wait(.ended(.nobodyUp), addition.conversation)
        await #expect(throws: ChangePlanError.unknownInteraction(invitation.id)) {
            try await n.service.answer(invitation.id, with: .accept(proposal: 1))
        }
        for phone in [a, c] {
            try await phone.waitRevision(1, origin: world.origin)
            #expect(try await phone.plan(world.origin).attendees.peers == [a.id, c.id])
        }
        #expect(try await n.all().allSatisfy { $0.plan == nil })
        await world.checkHealthy()
        await world.stop()
    }
}
