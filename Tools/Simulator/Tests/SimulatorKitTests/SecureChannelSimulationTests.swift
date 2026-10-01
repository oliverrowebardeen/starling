import Foundation
import SimulatorKit
import StarlingCore
import StarlingIdentity
import Testing

/// `LinkSecurity.secureChannel`: agents talk through lane E1's secure
/// channel, so a link's claimed peer ID is no longer enough (issue #8).
@Suite struct SecureChannelSimulationTests {
    @Test func secureAgentsFormAMeshOverProvenKeys() async throws {
        let simulation = Simulation(security: .secureChannel)
        for name in ["a", "b", "c"] { try await simulation.addAgent(name) }
        try await simulation.waitForMesh()
        let agents = await simulation.agents
        for agent in agents {
            #expect(await agent.peerCards.count == 2)
            for other in agents where other.id != agent.id {
                let status = try #require(await agent.secureTransport?.status(of: other.id))
                #expect(status.provenKey?.peerID == other.id)
            }
        }
        await simulation.stop()
    }

    /// Agents added at the same time must still all pin each other.
    @Test func concurrentlyAddedSecureAgentsStillFormAMesh() async throws {
        let simulation = Simulation(security: .secureChannel)
        try await simulation.addAgent("first")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in ["b", "c", "d", "e"] {
                group.addTask { try await simulation.addAgent(name) }
            }
            try await group.waitForAll()
        }
        try await simulation.waitForMesh()
        for agent in await simulation.agents {
            #expect(await agent.peerCards.count == 4)
        }
        await simulation.stop()
    }

    @Test func aForgedFrameClaimingAFriendNeverReachesTheInbox() async throws {
        let simulation = Simulation(security: .secureChannel)
        let alice = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob")
        try await simulation.waitForMesh()
        let bobSecure = try #require(bob.secureTransport)
        let receivedBefore = await bob.received.count
        let droppedBefore = await bobSecure.status(of: alice.id).droppedFrames

        // The Phase 0 impersonation: a plaintext envelope that names Alice,
        // injected on a link that claims to be Alice.
        let forged = try Envelope(
            conversation: ConversationID(), sender: alice.id, recipient: bob.id,
            sequence: 0, sentAt: Timestamp(Date()),
            body: .reject(Rejection(proposal: MessageID(), reason: .declinedByOwner))
        )
        try await simulation.hub.inject(Frame(EnvelopeCodec().encode(forged)), claimedSender: alice.id, to: bob.id)

        try await Simulation.eventually("bob's secure channel drops the forgery") {
            await bobSecure.status(of: alice.id).droppedFrames > droppedBefore
        }
        #expect(await bob.received.count == receivedBefore)
        #expect(await bob.dropped.isEmpty)
        // The real Alice is still Bob's friend on a live session.
        #expect(await bobSecure.status(of: alice.id).provenKey?.peerID == alice.id)
        await simulation.stop()
    }

    @Test func bareLoopbackStaysTheDefault() async throws {
        let simulation = Simulation(seed: 3)
        let agent = try await simulation.addAgent("a")
        #expect(agent.secureTransport == nil)
        #expect(simulation.security == .none)
        await simulation.stop()
    }
}
