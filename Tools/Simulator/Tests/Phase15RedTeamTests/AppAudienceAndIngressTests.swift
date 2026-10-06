import DownFor
import FindATime
import Foundation
import PickAPlace
import StarlingCore
import StarlingFeatures
import StarlingSwapPhotos
import Testing

@MainActor
@Suite("P15-F app audience and ingress", .serialized)
struct AppAudienceAndIngressTests {
    @Test func aVisibleSupportUpgradeMustNotEndAsUnsupported() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let old = try await b.outbox.send(.hello(b.agent.card), to: a.id, conversation: ConversationID())
        try await appEventually("old support card authenticated") { await a.agent.received.contains(old) }
        a.input?.yield(.message(old))
        try await a.handledHello(old)
        try await appEventually("old support card published") { a.app.cards.cards[b.id] == b.agent.card }
        await a.delivery.holdHello(from: b.id)
        let updated = try await b.outbox.send(.hello(#require(b.app.agentCard)), to: a.id, conversation: ConversationID())
        try await appEventually("new support card authenticated") { await a.agent.received.contains(updated) }
        a.input?.yield(.message(updated))
        try await appEventually("hello held before Down for handles it") { await a.delivery.holding }
        #expect(a.app.cards.cards[b.id] == b.agent.card)
        try await a.compose(.downFor, with: [b.id])
        #expect(a.app.composer.participants.isEmpty && a.app.composer.leftOutNote != nil)
        #expect(await a.app.composer.send() == nil)
        #expect(a.app.lifecycle.interactions.isEmpty)
        #expect(await a.wire.records.allSatisfy { $0.envelope.skill == nil })
        await a.delivery.release()
        try await a.handledHello(updated)
        try await appEventually("new support card published after skill delivery") { a.app.cards.cards[b.id] == b.app.agentCard }
        #expect(a.app.composer.participants == [b.id])
        let id = try #require(await a.app.composer.send())
        let owner = try #require(a.app.lifecycle.interaction(id))
        let card = try await b.incoming(owner.conversation)
        _ = try await b.wait(.proposed, card.id)
        #expect(a.app.lifecycle.interaction(id)?.state != .ended(.unsupported))
    }

    @Test func parsedExclusionsAndSavedRulesResolveBeforeAnyWireSend() async throws {
        let world = try await AppWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        await a.app.settings.setRule(.alwaysInclude, for: b.id)
        await a.app.settings.setRule(.quietOnly, for: c.id)
        try await a.model.set(ParsedIntent(constraints: AppPhone.rules(), audience: .everyoneExcept([]), mode: .invite, mentionedNames: [b.agent.name]))
        a.app.composer.text = "invite friends except one"
        await a.app.composer.understand()
        #expect(a.app.composer.participants.isEmpty)
        #expect(a.app.lifecycle.interactions.isEmpty)
        #expect(await a.wire.records.allSatisfy { $0.envelope.skill == nil })
        await a.app.settings.setRule(nil, for: c.id)
        #expect(a.app.composer.participants == [c.id])
        #expect(a.app.composer.sendMode == .invite)
        let id = try #require(await a.app.composer.send())
        let owner = try #require(a.app.lifecycle.interaction(id))
        let card = try await c.incoming(owner.conversation)
        _ = try await c.wait(.proposed, card.id)
        #expect(await b.agent.received.filter { $0.conversation == owner.conversation }.isEmpty)
        #expect(owner.participants == [c.id])
        let saved = a.app.settings.audienceBook
        try await a.restart()
        #expect(a.app.settings.audienceBook == saved)
        await a.app.settings.setRule(.neverInclude, for: b.id)
        try await a.compose(.downFor, with: [b.id], mode: .invite)
        #expect(a.app.composer.participants == [b.id])
    }

    @Test func ambiguousExclusionsAskNobodyAndGroupNamesStayLocal() async throws {
        let world = try await AppWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        for friend in try await a.peers.all() {
            try await a.peers.save(PairedPeer(publicKey: friend.publicKey, nickname: "Alex", pairedAt: friend.pairedAt))
        }
        await a.app.friends?.load()
        try await a.model.set(ParsedIntent(constraints: AppPhone.rules(), audience: .everyoneExcept([]), mode: .invite, mentionedNames: ["Alex"]))
        a.app.composer.text = "invite everyone except Alex"
        await a.app.composer.understand()
        #expect(a.app.composer.participants.isEmpty && a.app.composer.notice != nil)
        #expect(await a.app.composer.send() == nil)
        let group = try FriendGroup(name: "PRIVATE_LOCAL_GROUP", members: [b.id])
        await a.app.settings.saveGroup(group)
        try await a.model.set(ParsedIntent(constraints: AppPhone.rules(), mode: .invite, mentionedNames: [group.name]))
        a.app.composer.clear(); a.app.composer.text = "invite the saved group"
        await a.app.composer.understand()
        #expect(a.app.composer.audience == .group(group.id) && a.app.composer.participants == [b.id])
        let id = try #require(await a.app.composer.send())
        let owner = try #require(a.app.lifecycle.interaction(id))
        _ = try await b.incoming(owner.conversation)
        let wire = await a.sent(owner.conversation)
        #expect(!String(describing: wire).contains(group.name))
        #expect(!String(describing: wire).contains(group.id.description))
        #expect(await c.agent.received.filter { $0.conversation == owner.conversation }.isEmpty)
    }

    @Test func unsupportedModelModeAndMissingCardsFailLocallyWithoutPromptingPeers() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        try await a.model.set(ParsedIntent(constraints: AppPhone.rules(), audience: .picked([b.id]), mode: .askQuietly), skill: .findATime)
        a.app.composer.text = "find a time"
        await a.app.composer.understand()
        #expect(a.app.composer.sendMode == .invite && !a.app.composer.offersModeChoice)
        #expect(a.app.lifecycle.interactions.isEmpty && a.calendar.requestCount == 0)
        let incompatible = try P15.card([SkillRef(.downFor, SkillVersion(99))])
        let hello = try await b.outbox.send(.hello(incompatible), to: a.id, conversation: ConversationID())
        try await appEventually("incompatible card authenticated") { await a.agent.received.contains(hello) }
        a.input?.yield(.message(hello))
        try await appEventually("incompatible card installed") { a.app.cards.cards[b.id] == incompatible }
        try await a.compose(.downFor, with: [b.id])
        #expect(a.app.composer.participants.isEmpty && a.app.composer.leftOutNote != nil)
        #expect(await a.app.composer.send() == nil)
    }

    @Test func privacyRowsNeverChangeTheAdvertisedCardAndRequiredPlaceExplainsLocally() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let a = world.phones[0], b = world.phones[1]
        let card = a.app.agentCard
        for topic in PrivacyTopic.allCases where topic.allowsNever {
            await a.app.settings.set(.never, for: topic)
            #expect(a.app.agentCard == card)
        }
        try await a.compose(.pickAPlace, with: [b.id])
        #expect(a.app.composer.blocker == ComposerModel.blockedReason(PickAPlaceSkill.descriptor, [.place]))
        #expect(await a.app.composer.send() == nil)
        #expect(await a.wire.records.allSatisfy { $0.envelope.skill == nil })
        try await a.restart()
        #expect(PrivacyTopic.allCases.filter(\.allowsNever).allSatisfy { a.app.settings.choice(for: $0) == .never })
        #expect(a.app.agentCard == card)
    }

    @Test func peerHintsAndForgedSkillRefsCannotStartPermissionOrModelWorkInTheApp() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let a = world.phones[0], b = world.phones[1]
        #expect(b.app.lifecycle.service(for: .swapPhotos) == nil)
        let terms = try Terms([.activity: .keywords([Keyword("start swap photos")]), .time: .slots(AppPhone.slots())])
        let cases: [(SkillRef?, SendMode?)] = [(nil, nil), (SwapPhotos.descriptor.ref, .invite),
            (SkillRef(.downFor, SkillVersion(99)), .invite), (DownFor.ref, .askQuietly),
            (PickAPlaceSkill.ref, .askQuietly), (FindATimeSkill.ref, .askQuietly)]
        for (skill, mode) in cases {
            let sent = try await a.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: b.id, conversation: ConversationID(),
                recipientCard: b.app.agentCard, skill: skill, mode: mode, chainedFrom: ConversationID())
            try await appEventually("forged envelope accepted by Inbox") { await b.agent.received.contains(sent) }
        }
        let valid = try await a.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: b.id, conversation: ConversationID(),
            recipientCard: b.app.agentCard, skill: DownFor.ref, mode: .invite, chainedFrom: ConversationID())
        let invitee = try await b.incoming(valid.conversation)
        _ = try await b.wait(.proposed, invitee.id)
        // The valid card is the processing control after the forged inputs.
        #expect(b.app.lifecycle.interactions.map(\.id) == [invitee.id])
        #expect(invitee.chain == nil && invitee.friendChainHint == nil)
        #expect(b.app.permissions.pending == nil && b.app.consent.current == nil)
        #expect(b.calendar.requestCount == 0)
        #expect(await b.location.requests == 0)
        #expect(await b.model.routes.isEmpty)
        #expect(await b.matcher.interpretations == 0)
        #expect(await b.sent(valid.conversation).isEmpty)
        #expect(b.app.lifecycle.interactions.allSatisfy { $0.role == .invitee })
    }
}
