import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@MainActor
@Suite struct ConsentLifecycleTests {
    let maya = Fixtures.peer("Maya")
    let alexOne = Fixtures.peer("Alex")
    let alexTwo = Fixtures.peer("Alex")
    let me = PeerID.random()
    let down = ScriptedSkillService(descriptor: SampleSkills.downFor)

    func started(_ lifecycle: LifecycleCoordinator) async throws -> SkillRequest {
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: SampleSkills.downFor.ref, rules: .empty, audience: .allFriends, mode: SampleSkills.downFor.defaultSendMode, expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [maya.id]
        )
        try await lifecycle.start(request, settings: SkillSettings(flags: .phase1_5))
        return request
    }

    func disclosure(_ conversation: ConversationID?, roster: [PeerID] = []) throws -> Disclosure {
        var items = [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")]))]
        if !roster.isEmpty { items.append(DisclosedItem(category: .terms, issue: .people, value: .peers(roster))) }
        return Disclosure(recipient: maya.id, recipientModel: .onDevice, items: items, conversation: conversation, skill: SampleSkills.downFor.ref)
    }

    @Test func aSheetSuspendsItsInteractionAndApprovalResumesIt() async throws {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore())
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        consent.tracker = lifecycle
        let request = try await started(lifecycle)

        let sent = try disclosure(request.conversation)
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        #expect(lifecycle.interaction(request.interaction)?.state == .awaitingConsent(resume: .negotiating))

        consent.answer(.approved, to: consent.current!.id)
        #expect(await ask.value == .approved)
        #expect(lifecycle.interaction(request.interaction)?.state == .negotiating)
    }

    @Test func aDeclinedOrTimedOutSheetEndsTheInteractionDeclined() async throws {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore())
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]), timeout: .milliseconds(50))
        consent.tracker = lifecycle
        let request = try await started(lifecycle)
        let sent = try disclosure(request.conversation)
        #expect(await consent.requestConsent(for: sent) == .declined)
        #expect(lifecycle.interaction(request.interaction)?.state == .ended(.declined))
    }

    @Test func aSendOutsideAnyInteractionAsksWithoutTouchingTheLifecycle() async throws {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore())
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        consent.tracker = lifecycle
        let request = try await started(lifecycle)
        let sent = try disclosure(nil)
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        consent.answer(.declined, to: consent.current!.id)
        #expect(await ask.value == .declined)
        #expect(lifecycle.interaction(request.interaction)?.state == .negotiating)
        #expect(lifecycle.dropped.isEmpty)
    }

    /// Review of PR #54, finding 3: a sheet still queued when its
    /// interaction ends is withdrawn as a decline, and nothing is sent.
    @Test func aQueuedSheetForAnEndedInteractionCannotBeApproved() async throws {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore())
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        consent.tracker = lifecycle
        lifecycle.onFinished = { consent.invalidate(interaction: $0, conversation: $1) }
        let request = try await started(lifecycle)
        let sent = try disclosure(request.conversation)
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        let sheet = try #require(consent.current)

        await lifecycle.withdraw(request.interaction)
        #expect(await ask.value == .declined)
        #expect(consent.current == nil)
        // A late tap on the sheet that was on screen does nothing.
        consent.answer(.approved, to: sheet.id)
        // And a retry for the ended interaction is declined at once.
        #expect(await consent.requestConsent(for: sent) == .declined)
    }

    /// An approval the lifecycle cannot apply is a decline, and it is not
    /// remembered for later sends.
    @Test func anApprovalThatDoesNotApplyIsADecline() async throws {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore())
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        consent.tracker = lifecycle
        let request = try await started(lifecycle)
        let sent = try disclosure(request.conversation)
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        // The interaction ends without the coordinator's hook, so the sheet
        // is still up when the owner approves.
        await lifecycle.handle(.lifecycle(request.interaction, .expired), from: SampleSkills.downFor)
        consent.answer(.approved, to: consent.current!.id)
        #expect(await ask.value == .declined)
        #expect(await consent.requestConsent(for: sent) == .declined)
    }

    /// Amendment 15: a send cancelled while its sheet is up dismisses the
    /// sheet and resumes the step with consentCancelled, not a pass.
    @Test func aCancelledSendDismissesItsSheetAndResumesTheStep() async throws {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore())
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        consent.tracker = lifecycle
        let request = try await started(lifecycle)
        let sent = try disclosure(request.conversation)
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        #expect(lifecycle.interaction(request.interaction)?.state == .awaitingConsent(resume: .negotiating))

        ask.cancel()
        #expect(await ask.value == .declined)
        await eventually { consent.current == nil }
        #expect(consent.current == nil)
        let after = try #require(lifecycle.interaction(request.interaction))
        #expect(after.state == .negotiating)
        #expect(after.pendingConsents.isEmpty)
        #expect(lifecycle.dropped.isEmpty)
    }

    /// Core v2.1: the interaction the service named wins over the
    /// conversation, which a group member shares with the starter.
    @Test func theNamedInteractionIsTheOneSuspended() async throws {
        let conversation = ConversationID()
        var starter = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya.id], createdAt: Timestamp(Date()))
        try starter.apply(.started, at: Timestamp(Date()))
        let member = Interaction(conversation: conversation, skill: SampleSkills.downFor.ref, role: .invitee, participants: [maya.id], createdAt: Timestamp(Date()))
        let other = Interaction(conversation: conversation, skill: SampleSkills.downFor.ref, role: .invitee, participants: [maya.id], createdAt: Timestamp(Date().addingTimeInterval(-1)))
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down], store: InMemoryInteractionStore([starter, other, member]))
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        consent.tracker = lifecycle
        await lifecycle.start()

        let sent = Disclosure(recipient: maya.id, recipientModel: .onDevice, items: [], conversation: conversation, skill: SampleSkills.downFor.ref, interaction: member.id)
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        #expect(lifecycle.interaction(member.id)?.state == .awaitingConsent(resume: .negotiating))
        #expect(lifecycle.interaction(other.id)?.state == .negotiating)
        consent.answer(.approved, to: consent.current!.id)
        #expect(await ask.value == .approved)
        #expect(lifecycle.interaction(member.id)?.state == .negotiating)
    }

    /// Issue #46: one row per person, two friends with one nickname told
    /// apart, the owner as "You", and a stranger shown with their full ID
    /// and no symbol.
    @Test func rostersShowOneRowPerPerson() async throws {
        let stranger = PeerID.random()
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya, alexOne, alexTwo]), localPeer: me)
        let sent = try disclosure(nil, roster: [me, alexOne.id, alexTwo.id, stranger])
        let ask = Task { await consent.requestConsent(for: sent) }
        await eventually { consent.current != nil }
        let request = try #require(consent.current)
        #expect(request.rosters.count == request.items.count)
        #expect(request.rosters[0].isEmpty)
        let rows = request.rosters[1]
        #expect(rows.map(\.peer) == [me, alexOne.id, alexTwo.id, stranger])
        #expect(rows[0].label == "You")
        #expect(rows[1].label == "Alex (\(alexOne.id.fingerprint))")
        #expect(rows[2].label == "Alex (\(alexTwo.id.fingerprint))")
        #expect(rows[3].label.hasPrefix(RosterLabels.stranger))
        #expect(rows.map(\.isKnown) == [true, true, true, false])
        #expect(request.recipientIsFriend)
        consent.answer(.declined, to: request.id)
        _ = await ask.value
    }

    @Test func aRecipientSharingANicknameIsToldApartInTheTitle() async throws {
        let consent = ConsentCoordinator(peers: InMemoryPairedPeerStore([alexOne, alexTwo]))
        let disclosure = Disclosure(recipient: alexTwo.id, recipientModel: .onDevice, items: [])
        let ask = Task { await consent.requestConsent(for: disclosure) }
        await eventually { consent.current != nil }
        #expect(consent.current?.recipientName == "Alex (\(alexTwo.id.fingerprint))")
        consent.answer(.declined, to: consent.current!.id)
        _ = await ask.value
    }
}
