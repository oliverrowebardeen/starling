import Scenarios
import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import Testing

@Suite struct SimulationTests {
    @Test func agentsExchangeCardsAcrossAMesh() async throws {
        let simulation = Simulation(seed: 1)
        for name in ["a", "b", "c", "d", "e"] { try await simulation.addAgent(name) }
        try await AwakeWait.mesh(simulation)
        for agent in await simulation.agents {
            #expect(await agent.peerCards.count == 4)
        }
        await simulation.stop()
    }

    @Test func seededSimulationsAreReproducible() async throws {
        func ids(seed: UInt64) async throws -> [PeerID] {
            let simulation = Simulation(seed: seed)
            var result: [PeerID] = []
            for name in ["a", "b"] { result.append(try await simulation.addAgent(name).id) }
            await simulation.stop()
            return result
        }
        #expect(try await ids(seed: 9) == ids(seed: 9))
        #expect(try await ids(seed: 9) != ids(seed: 10))
    }

    @Test func agentSendsGoThroughPolicy() async throws {
        let simulation = Simulation()
        let violation = PolicyViolation(rule: "deny-all")
        let policy = FixedPolicyEngine(.deny(violation))
        let alice = try await simulation.addAgent("alice", policy: policy)
        let bob = try await simulation.addAgent("bob")
        try await AwakeWait.eventually("alice sees bob") { await alice.log.contains { $0.event == .peerAvailable(bob.id) } }

        await #expect(throws: OutboxError.denied(violation)) {
            try await alice.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: bob.id)
        }
        // Even the automatic hello was blocked, so Bob never learned Alice's card.
        #expect(await bob.peerCards[alice.id] == nil)
        #expect(await !policy.evaluated.isEmpty)
        await simulation.stop()
    }
}
