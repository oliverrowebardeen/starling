import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// Every ending retires its conversation for good, and a retired
/// conversation is never answered or opened again (ADR 0021).
@Suite("Retired conversations", .serialized)
struct RetirementTests {
    let skill = PickAPlaceSkill.ref
    let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                        answerWindow: .seconds(3), confirmWindow: .milliseconds(600))

    func query(_ places: [PlaceChoice]) throws -> MessageBody {
        .query(try Query(issue: .place, candidates: .places(places)))
    }

    @Test func aFriendWhomNothingFitsRetiresAndNeverAnswersAgain() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(avoid: ["boba", "restaurant"]))
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await mallory.outbox.send(query(Venues.all.map(\.choice)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await (try? maya.conversations.isRetired(conversation)) == true })
        let noes = await group.wire.sent(by: maya.id)
        #expect(noes.count == 1 && noes.first?.body.rejection?.reason == .noOverlap)

        // Asked again, after a relaunch, about a place that would fit her:
        // nothing opens, and nothing is sent.
        await maya.restart()
        let cafe = candidate("Corner Cafe", id: "I.corner", tier: .one, kinds: ["cafe"])
        await maps.add(cafe)
        try await mallory.outbox.send(query([cafe.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await group.wire.sent(by: maya.id).count == 1)
        #expect(await maya.coordinator.incoming.isEmpty)
    }

    @Test func everyEndingRetiresItsConversation() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        // A plan stays open while it stands, and retires when called off.
        let planned = try await oliver.organize(Venues.all, with: [maya])
        for phone in [oliver, maya] { #expect(await phone.reaches(.proposed, in: planned.conversation)) }
        for phone in [maya, oliver] { try await phone.accept(in: planned.conversation) }
        for phone in [oliver, maya] { #expect(await phone.reaches(.planned, in: planned.conversation)) }
        #expect(try await oliver.conversations.isRetired(planned.conversation) == false)
        await oliver.service.withdraw(planned.id)
        for phone in [oliver, maya] {
            #expect(await eventually { await (try? phone.conversations.isRetired(planned.conversation)) == true }, "\(phone.name)")
        }

        // A friend's withdrawal before saying yes retires the conversation
        // on the friend's phone at once.
        let asked = try await oliver.organize(Venues.all, with: [maya])
        #expect(await eventually { await maya.interaction(asked.conversation) != nil })
        let mayas = try #require(await maya.interaction(asked.conversation)?.id)
        await maya.service.withdraw(mayas)
        #expect(await eventually { await (try? maya.conversations.isRetired(asked.conversation)) == true })

        // An organizer's expiry.
        let expiring = try await oliver.organize(Venues.all, with: [maya], expiresIn: 0.3)
        #expect(await oliver.reaches(.ended(.expired), in: expiring.conversation))
        #expect(await eventually { await (try? oliver.conversations.isRetired(expiring.conversation)) == true })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aYesTakenBackRetiresOnceTheOrganizerHearsIt() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        await maya.transport.lose(2) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        // Not retired while the no is still being retried...
        #expect(try await maya.conversations.isRetired(conversation) == false)
        // ...and retired once Oliver acknowledges it.
        #expect(await eventually { await (try? maya.conversations.isRetired(conversation)) == true })
        #expect(await maya.service.pendingWithdrawals.isEmpty)
        #expect(await oliver.service.organized[conversation]?.passed.contains(maya.id) == true)
    }

    /// Lane E's review (ADR 0021): a terminal event is reported only once
    /// its conversation is retired, so a crash in between can never leave a
    /// reported ending open to a new request.
    @Test func everyEndingIsReportedOnlyOnceRetired() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: quick)
        let group = try await Group([oliver, maya, jake], hub: hub)
        defer { Task { await group.stop() } }

        // Jake passes on a card; Maya and Oliver plan, then Oliver calls it off.
        let first = try await oliver.organize(Venues.all, with: [maya, jake])
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: first.conversation)) }
        try await jake.pass(in: first.conversation)
        for phone in [maya, oliver] { try await phone.accept(in: first.conversation) }
        #expect(await oliver.reaches(.planned, in: first.conversation, within: 3))
        await oliver.service.withdraw(first.id)
        #expect(await maya.reaches(.ended(.withdrawn), in: first.conversation))

        // Oliver withdraws a request still being asked about.
        let second = try await oliver.organize(Venues.all, with: [maya, jake])
        #expect(await eventually { await maya.interaction(second.conversation) != nil })
        await oliver.service.withdraw(second.id)
        #expect(await maya.reaches(.ended(.nobodyUp), in: second.conversation))

        // A request that expires.
        let third = try await oliver.organize(Venues.all, with: [maya], expiresIn: 0.3)
        #expect(await oliver.reaches(.ended(.expired), in: third.conversation))
        #expect(await maya.reaches(.ended(.expired), in: third.conversation))

        for phone in [oliver, maya, jake] {
            let endings = phone.endings.withLock { $0 }
            #expect(!endings.isEmpty, "\(phone.name)")
            #expect(endings.allSatisfy { $0.retired }, "\(phone.name): \(endings.map(\.event))")
        }
        #expect(await group.lifecyclesWereLegal())
    }

    /// A yes taken back keeps its conversation open for the retried no; its
    /// ending is reported only once the withdrawal is durably recorded.
    @Test func aYesTakenBackIsReportedOnlyOnceRecorded() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        await maya.transport.lose(.max) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
        let ending = try #require(maya.endings.withLock { $0 }.first { $0.event == .withdrawn })
        #expect(ending.withdrawalRecorded)
        #expect(!ending.retired)
    }

    @Test(arguments: [true, false])
    func aRetirementThatFailsIsReportedAsFailed(organizerFails: Bool) async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya])
        for phone in [oliver, maya] { #expect(await phone.reaches(.proposed, in: request.conversation)) }

        let phone = organizerFails ? oliver : maya
        await phone.conversations.failAll()
        if organizerFails {
            await oliver.service.withdraw(request.id)
        } else {
            try await maya.pass(in: request.conversation)
        }
        // Not a clean ending: failed, and closed for this launch.
        #expect(await phone.reaches(.ended(.failed), in: request.conversation))
        #expect(await phone.service.unretired.contains(request.conversation))
    }
}

