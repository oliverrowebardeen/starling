import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct SkillFakesTests {
    @Test func sampleRegistryShipsThreeSkillsAndChainsToPickAPlace() {
        let settings = SkillSettings(flags: .phase1_5)
        #expect(SampleSkills.registry.inBuild(.phase1_5).map(\.id) == [.downFor, .findATime, .pickAPlace])
        let peer = try! AgentCard(model: .onDevice, capabilities: [], skills: SampleSkills.registry.advertised(in: settings))
        #expect(SampleSkills.registry.chainSuggestions(after: .downFor, in: settings, peers: [peer]).map(\.id) == [.pickAPlace])
        #expect(SampleSkills.swapPhotos.chainTrigger == .afterPlanEnds)
    }

    @Test func scriptedServiceRecordsAndEmits() async throws {
        let service = ScriptedSkillService(descriptor: SampleSkills.downFor)
        let id = InteractionID()
        await service.emit(.lifecycle(id, .proposalReady(revision: 1)))
        try await service.answer(id, with: .accept(proposal: 1))
        var iterator = service.events.makeAsyncIterator()
        #expect(await iterator.next() == .lifecycle(id, .proposalReady(revision: 1)))
        #expect(await service.answers.map(\.1) == [.accept(proposal: 1)])
    }

    @Test func inMemoryStoreFindsByConversation() async throws {
        let store = InMemoryInteractionStore()
        let interaction = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [PeerID.random()], createdAt: Timestamp(Date()))
        try await store.save(interaction)
        #expect(try await store.interaction(conversation: interaction.conversation) == interaction)
        try await store.remove(interaction.id)
        #expect(try await store.all().isEmpty)
    }
}
