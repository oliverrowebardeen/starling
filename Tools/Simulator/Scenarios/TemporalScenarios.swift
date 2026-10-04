import Foundation
import SimulatorKit
import StarlingCore
import StarlingTransport

extension ScenarioRunner {
    static func temporal(_ scenario: Scenario, simulation: Simulation) async throws -> ScenarioOutcome {
        let alice = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob")
        try await AwakeWait.mesh(simulation)
        let conversation = ConversationID()
        let timestamp = Timestamp(now).millisecondsSince1970
        let inputs: [(UInt64, Int64)]
        switch scenario {
        case .reorder:
            inputs = [2, 0, 1, 1].map { ($0, timestamp) }
        case .replayWindow:
            inputs = [64, 0, 1, UInt64.max, UInt64.max - 63, UInt64.max - 64, UInt64.max, 0].map { ($0, timestamp) }
        case .stale:
            inputs = [(1000, .min), (1001, timestamp - 600_001), (0, timestamp - 600_000), (1, timestamp)]
        case .futureDated:
            inputs = [(1000, .max), (1001, timestamp + 120_001), (0, timestamp + 120_000), (1, timestamp)]
        default:
            preconditionFailure("Not a temporal scenario")
        }

        for (index, input) in inputs.enumerated() {
            let envelope = try Envelope(
                conversation: conversation, sender: alice.id, recipient: bob.id,
                sequence: input.0, sentAt: Timestamp(millisecondsSince1970: input.1),
                body: .reject(Rejection(proposal: MessageID(), reason: .noOverlap))
            )
            // The malicious-wire hook is deliberate. Honest sends still use Outbox.
            try await simulation.hub.inject(Frame(EnvelopeCodec().encode(envelope)), claimedSender: alice.id, to: bob.id)
            try await AwakeWait.eventually("bob processes temporal frame \(index)") {
                let accepted = await bob.received.filter { $0.conversation == conversation }.count
                let dropped = await bob.dropped.count
                return accepted + dropped == index + 1
            }
        }
        return ScenarioOutcome(
            transcript: await simulation.transcript(),
            accepted: await bob.received.filter { $0.conversation == conversation },
            dropped: await bob.dropped
        )
    }
}
