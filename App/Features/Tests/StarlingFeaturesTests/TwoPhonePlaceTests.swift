import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// Review of #118 (high): a friend's phone never stored the agreed place,
/// because only this phone's own link moved the plan. Two phones, each
/// with the real coordinator and AppModel; their Pick a place services are
/// scripted to report what the real ones do on each side.
@MainActor
@Suite struct TwoPhonePlaceTests {
    let a = PeerID.random()
    let b = PeerID.random()

    /// One phone holding the plan both agreed (origin: A's conversation).
    struct Phone {
        let app: AppModel
        let root: Interaction
        let built: AppModelTests.Built
        var place: ScriptedSkillService { built.services.first { $0.descriptor.id == .pickAPlace }! }
    }

    func phone(_ me: PeerID, friend: PeerID, plan: Plan, role: InteractionRole, conversation: ConversationID) async throws -> Phone {
        var root = Interaction(conversation: conversation, skill: SampleSkills.downFor.ref, role: role, participants: [friend], createdAt: Timestamp(Date()))
        let proposal = SkillProposal(revision: 1, participants: plan.attendees.peers, terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        let events: [InteractionEvent] = role == .initiator
            ? [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)]
            : [.proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)]
        for event in events { try root.apply(event, at: Timestamp(Date())) }
        root.record(.plan(plan))
        let built = AppModelTests.Built()
        var services = AppModelTests.services(skills: [SampleSkills.downFor, SampleSkills.pickAPlace], built: built, transport: RecordingTransport(localPeer: me))
        services.interactions = InMemoryInteractionStore([root])
        let app = AppModel(services: services)
        await app.start()
        return Phone(app: app, root: root, built: built)
    }

    @Test func bothPhonesStoreTheAgreedPlaceAtTheNextRevision() async throws {
        let conversation = ConversationID()
        let start = Date().addingTimeInterval(3 * 3600)
        let plan = try Plan(origin: conversation, attendees: Attendees([a, b]), activity: Keyword("boba"), time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))
        let organizer = try await phone(a, friend: b, plan: plan, role: .initiator, conversation: conversation)
        let friend = try await phone(b, friend: a, plan: plan, role: .invitee, conversation: conversation)
        let place = try PlaceChoice(name: PlaceName("Boba Guys"))
        let agreed = plan.updating(place: place)
        let terms = try Terms([.place: .places([place])])
        let roster = try Attendees([a, b])

        // A: "Somewhere else?" from the plan, a link to its interaction.
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: SampleSkills.pickAPlace.ref, rules: .empty, audience: .picked([b]), mode: .invite, expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [b], inputs: [.plan(plan)], chainedFrom: plan.origin
        )
        let link = ChainLink(parent: organizer.root.id, parentConversation: plan.origin, consumed: [.plan], trigger: .atConfirm, optedInAt: Timestamp(Date()))
        let mine = try await organizer.app.lifecycle.start(request, chain: link, settings: organizer.app.settings.skillSettings)

        // B: the friend's request, grouped under the plan by its hint.
        let theirs = InteractionID()
        await friend.place.emit(.incoming(theirs, conversation: request.conversation, from: a, chainedFrom: plan.origin))
        await eventually { friend.app.lifecycle.interaction(theirs) != nil }
        #expect(friend.app.lifecycle.interaction(theirs)?.friendChainHint == plan.origin)

        // Both agree; each service reports the agreed place and roster.
        for (phone, id) in [(organizer, mine), (friend, theirs)] {
            await phone.place.emit(.lifecycle(id, .proposalReady(SkillProposal(revision: 1, participants: [a, b], terms: terms, plan: agreed))))
            await eventually { phone.app.lifecycle.interaction(id)?.state == .proposed }
            #expect(await phone.app.lifecycle.answer(id, with: .accept(proposal: 1)))
            await phone.place.emit(.lifecycle(id, .everyoneConfirmed(revision: 1)))
            await phone.place.emit(.produced(id, .attendees(roster)))
            await phone.place.emit(.produced(id, .placeChoice(place)))
            await eventually { phone.app.lifecycle.interaction(phone.root.id)?.plan?.place == place }
        }

        for phone in [organizer, friend] {
            let stored = try #require(phone.app.lifecycle.interaction(phone.root.id)?.plan)
            #expect(stored.place == place)
            #expect(stored.revision == plan.revision + 1)
            #expect(stored.attendees == plan.attendees)
        }
        await organizer.app.shutdown()
        await friend.app.shutdown()
    }
}
