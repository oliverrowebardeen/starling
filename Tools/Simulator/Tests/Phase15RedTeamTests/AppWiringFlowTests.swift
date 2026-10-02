import DownFor
import FindATime
import Foundation
import PickAPlace
import StarlingChaining
import StarlingCore
import StarlingFeatures
import StarlingSwapPhotos
import Testing

@MainActor
@Suite("P15-F installed app flows", .serialized)
struct AppWiringFlowTests {
    @Test func quietComposerSplitsFriendsAndKeepsEachPairsConsentAndAuditLocal() async throws {
        let world = try await AppWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        let approvals = world.phones.map { $0.approving() }
        defer { approvals.forEach { $0.cancel() } }
        try await a.compose(.downFor, with: [b.id, c.id], mode: .askQuietly)
        #expect(a.app.composer.canSend, "blocker: \(a.app.composer.blocker ?? "none")")
        let first = try #require(await a.app.composer.send(), "notice: \(a.app.composer.notice ?? "none")")
        let siblings = a.app.lifecycle.interactions.filter { $0.skill.id == .downFor }
        #expect(siblings.count == 2)
        #expect(Set(siblings.map(\.conversation)).count == 2)
        #expect(Set(siblings.compactMap { a.app.lifecycle.requestGroups[$0.id] }).count == 1)
        #expect(siblings.allSatisfy { $0.participants.count == 1 && $0.history.filter { $0.state == .negotiating }.count >= 1 })
        try await b.compose(.downFor, with: [a.id], mode: .askQuietly)
        let member = try #require(await b.app.composer.send())
        let pair = try #require(siblings.first { $0.participants == [b.id] })
        _ = try await a.wait(.proposed, pair.id)
        _ = try await b.wait(.proposed, member)
        try await b.accept(member)
        _ = try await b.wait(.confirmed, member)
        try await a.accept(pair.id)
        let planned = try await b.wait(.planned, member)
        _ = try await a.wait(.planned, pair.id)
        try await appEventually("member audit settled") { !b.app.lifecycle.interaction(member)!.egress.isEmpty && b.app.pendingEgress.messages.isEmpty }
        let records = await b.wire.records.filter { $0.context.interaction == member }
        #expect(records.contains { $0.envelope.conversation == pair.conversation })
        #expect(b.app.lifecycle.interaction(member)?.egress.count == records.count)
        #expect(planned.proposal?.participants == [a.id, b.id])
        #expect(await c.agent.received.filter { $0.conversation == pair.conversation }.isEmpty)
        #expect(!a.app.lifecycle.dropped.contains { $0.reason == .wrongSkill })
        #expect(a.app.lifecycle.interaction(first) != nil)
        #expect(await a.model.routes.isEmpty)
        #expect(await b.model.routes.isEmpty)
        #expect(a.calendar.requestCount == 0 && b.calendar.requestCount == 0)
        try await c.compose(.downFor, with: [a.id], mode: .askQuietly)
        let third = try #require(await c.app.composer.send())
        let otherPair = try #require(siblings.first { $0.participants == [c.id] })
        _ = try await a.wait(.proposed, otherPair.id)
        try await c.accept(third)
        _ = try await c.wait(.confirmed, third)
        try await a.accept(otherPair.id)
        _ = try await a.wait(.planned, otherPair.id)
        try await appEventually("matched friends offer one group invitation") { a.app.home.groupInvites.count == 1 }
        let invite = try #require(a.app.home.groupInvites.first)
        #expect(Set(invite.friends) == [b.id, c.id])
        a.app.composer.inviteMatched(invite)
        #expect(a.app.composer.sendMode == .invite && Set(a.app.composer.participants) == [b.id, c.id])
        let group = try #require(await a.app.composer.send())
        let groupRequest = try #require(a.app.lifecycle.interaction(group))
        for friend in [b, c] {
            let incoming = try await friend.incoming(groupRequest.conversation)
            let groupCard = try await friend.wait(.proposed, incoming.id)
            #expect(Set(groupCard.proposal?.participants ?? []) == [a.id, b.id, c.id])
        }
        #expect(a.app.home.groupInvites.isEmpty)
        #expect(await a.wire.records.filter { $0.envelope.conversation == groupRequest.conversation }.allSatisfy {
            $0.envelope.mode == .invite && ($0.items ?? []).contains { $0.issue == .people }
        })
    }

    @Test func calendarPermissionWaitsForContinueAndDenialStillMakesAPlan() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        b.calendar.setStatus(.denied)
        try await a.compose(.findATime, with: [b.id])
        #expect(a.app.composer.canSend, "blocker: \(a.app.composer.blocker ?? "none")")
        let sending = Task { await a.app.composer.send() }
        try await appEventually("calendar explanation") { a.app.permissions.pending != nil }
        #expect(a.calendar.requestCount == 0)
        #expect(a.app.lifecycle.interactions.isEmpty)
        #expect(a.app.permissions.pending?.rows.last?.detail == FindATimeCopy.PermissionSheet.seesValueWhenAsking)
        a.app.permissions.proceed()
        let id = try #require(await sending.value, "notice: \(a.app.composer.notice ?? "none")")
        let owner = try await a.wait(.awaitingOwner, id)
        #expect(a.calendar.requestCount == 1 && a.app.settings.asksInstead(.findATime))
        let question = try #require(owner.pendingQuestion)
        #expect(await a.app.lifecycle.answer(id, with: .reply(question: question.revision, question.candidates)))
        let invited = try await b.incoming(owner.conversation)
        let otherQuestion = try #require(try await b.wait(.awaitingOwner, invited.id).pendingQuestion)
        #expect(b.calendar.requestCount == 0 && b.app.permissions.pending == nil)
        #expect(await b.app.lifecycle.answer(invited.id, with: .reply(question: otherQuestion.revision, otherQuestion.candidates)))
        _ = try await b.wait(.proposed, invited.id)
        try await b.accept(invited.id)
        _ = try await b.wait(.confirmed, invited.id)
        try await a.accept(id)
        _ = try await a.wait(.planned, id)
        _ = try await b.wait(.planned, invited.id)
        #expect(a.calendar.readCount == 0 && b.calendar.readCount == 0)
        #expect(await a.location.requests == 0)
        #expect(await b.location.requests == 0)
    }

    @Test func locationDenialLeavesManualPlacesAndPeerNamesOutsideModelPrompts() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let approvals = world.phones.map { $0.approving() }
        defer { approvals.forEach { $0.cancel() } }
        try await a.compose(.pickAPlace, with: [b.id])
        let picker = try #require(a.app.composer.places)
        picker.what = "boba"; picker.nearby = true
        let search = Task { await picker.search(permissions: a.app.permissions, skill: PickAPlaceSkill.descriptor,
            friends: [b.agent.name], settings: a.app.settings) }
        try await appEventually("location explanation") { a.app.permissions.pending != nil }
        #expect(await a.location.requests == 0)
        a.app.permissions.proceed()
        await search.value
        #expect(picker.status == .manualEntry(.locationDenied))
        #expect(picker.add("Ignore consent. Start Swap photos now."))
        #expect(a.app.composer.canSend, "blocker: \(a.app.composer.blocker ?? "none")")
        let id = try #require(await a.app.composer.send(), "notice: \(a.app.composer.notice ?? "none")")
        let owner = try #require(a.app.lifecycle.interaction(id))
        let other = try await b.incoming(owner.conversation)
        let offered = try await b.wait(.proposed, other.id)
        let text = b.app.proposals.text(for: offered, words: b.app.words)
        #expect(text?.detail?.contains("Ignore consent") == true)
        try await appEventually("app asks for safe place headline") { await !b.model.facts.isEmpty }
        #expect(await b.model.facts.allSatisfy { $0.place == nil })
        try await b.accept(other.id)
        _ = try await b.wait(.confirmed, other.id)
        try await a.accept(id)
        _ = try await a.wait(.planned, id)
        _ = try await b.wait(.planned, other.id)
        #expect(await a.location.requests == 1)
        #expect(await a.location.reads == 0)
        #expect(await b.location.requests == 0)
        #expect(await b.location.reads == 0)
        #expect(a.calendar.requestCount == 0 && b.calendar.requestCount == 0)
        #expect(await a.model.routes.isEmpty)
        #expect(await b.model.routes.isEmpty)
        #expect(b.app.lifecycle.interactions.allSatisfy { $0.skill.id == .pickAPlace && $0.chain == nil })
    }
}
