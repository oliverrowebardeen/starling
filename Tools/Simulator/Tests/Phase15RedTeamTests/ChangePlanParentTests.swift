import DownFor
import FindATime
import Foundation
import SimulatorKit
import StarlingChaining
import StarlingChangePlan
import StarlingAvailabilityFakes
import StarlingCore
import Testing

struct ChangePlanParentTests {
    /// Retain the actual authenticated connections and independently produced
    /// plans. Only the active skill on each phone changes for the next owner tap.
    private func adopt(_ base: PlaceWorld, phones: [PlacePhone], roots: [Interaction]) async throws -> ChangeWorld {
        let clock = ChangeClock()
        let origin = try #require(roots.first?.plan?.origin)
        var changed: [ChangePhone] = []
        for (index, previous) in phones.enumerated() {
            let relay = ChangeRelay()
            let phone = try ChangePhone(agent: previous.agent, relay: relay, clock: clock,
                choices: [.people: .share, .place: .share])
            for peer in try await previous.peers.all() { try await phone.peers.save(peer) }
            try await phone.events.add(roots[index])
            try await phone.boot()
            // Simulation already owns this PlaceRelay as its Inbox behavior.
            // It forwards the authenticated message to the same real service.
            await previous.relay.attach(phone.service)
            changed.append(phone)
        }
        return ChangeWorld(simulation: base.simulation, phones: changed, origin: origin, clock: clock)
    }

    private func changeFromOriginalInvitee(_ world: ChangeWorld, roots: [Interaction]) async throws {
        let before = try roots.map { try #require($0.plan) }
        #expect(Set(before.map(\.id)).count == roots.count)
        #expect(Set(before.map(\.origin)).count == 1)
        let change = try await world.start(by: 1)
        try await world.phones[0].accept(change.conversation)
        for (index, phone) in world.phones.enumerated() {
            _ = try await phone.wait(.planned, change.conversation)
            try await P15.eventually("real parent receives its update") { try await phone.plan(world.origin).revision == 1 }
            #expect(try await phone.plan(world.origin) == before[index].updating(activity: .some(ChangeWorld.changedActivity)))
        }
        await world.checkHealthy()
    }

    @Test func pc28AnOriginalDownForInviteeChangesTheActualSharedPlan() async throws {
        let original = try await DownWorld.make(2, choices: [.people: .share])
        let a = original.phones[0], b = original.phones[1]
        let request = try await a.start(with: [b.id], mode: .invite)
        try await P15.eventually("real Down for invitation") { try await b.events.interaction(request.conversation)?.state == .proposed }
        let card = try #require(try await b.events.interaction(request.conversation))
        try await b.accept(card)
        try await a.accept(request)
        _ = try await a.wait(.planned, request)
        _ = try await b.wait(.planned, card)
        try await P15.eventually("both Down for plan artifacts") {
            let mine = try await a.events.store.interaction(request.id)?.plan
            let theirs = try await b.events.store.interaction(card.id)?.plan
            return mine != nil && theirs != nil
        }
        let roots = try await [#require(a.events.store.interaction(request.id)), #require(b.events.store.interaction(card.id))]
        await a.stop(); await b.stop()
        let changed = try await adopt(original.base, phones: [a.phone, b.phone], roots: roots)
        try await changeFromOriginalInvitee(changed, roots: roots)
        await changed.stop()
        await original.stop()
    }

    @Test func pc28AnOriginalFindATimeInviteeChangesTheActualSharedPlan() async throws {
        let base = try await PlaceWorld.make(count: 2)
        let a = TimePhone(base.phones[0], calendar: FakeCalendarStore())
        let b = TimePhone(base.phones[1], calendar: FakeCalendarStore())
        for from in [a.phone, b.phone] {
            let other = from.id == a.phone.id ? b : a
            let hello = try await from.outbox.send(.hello(P15.card([FindATimeSkill.ref])), to: other.phone.id, conversation: ConversationID())
            try await P15.eventually("time capability reaches peer") { await other.phone.agent.received.contains(hello) }
        }
        try await a.boot(); try await b.boot()
        let request = try await a.start(with: [b.phone.id], slots: FindTimeIntegrationTests.slots())
        let mine = try await a.wait(.proposed, in: request.conversation)
        let theirs = try await b.wait(.proposed, in: request.conversation)
        try await a.service.answer(mine.id, with: .accept(proposal: #require(mine.proposalRevision)))
        try await b.service.answer(theirs.id, with: .accept(proposal: #require(theirs.proposalRevision)))
        _ = try await a.wait(.planned, in: request.conversation)
        _ = try await b.wait(.planned, in: request.conversation)
        try await P15.eventually("both time plan artifacts") {
            let first = try await a.events.store.interaction(mine.id)?.plan
            let second = try await b.events.store.interaction(theirs.id)?.plan
            return first != nil && second != nil
        }
        let roots = try await [#require(a.events.store.interaction(mine.id)), #require(b.events.store.interaction(theirs.id))]
        await a.stop(); await b.stop()
        let changed = try await adopt(base, phones: [a.phone, b.phone], roots: roots)
        try await changeFromOriginalInvitee(changed, roots: roots)
        await changed.stop()
        await base.stop()
    }
}
