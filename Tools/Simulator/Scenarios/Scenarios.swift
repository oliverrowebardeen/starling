import Foundation
import SimulatorKit
import StarlingCore
import StarlingTransport

/// Named scenarios for tests and the `starling-sim` CLI.
/// Owned by the red team lane (brief section 6, lane I).
public enum Scenario: String, CaseIterable, Sendable {
    case helloMesh = "hello-mesh"
    case proposeAccept = "propose-accept"
    case replay
    case reorder
    case replayWindow = "replay-window"
    case stale
    case futureDated = "future-dated"
    case senderMismatch = "sender-mismatch"
    case impersonation
    case garbage

    public var summary: String {
        switch self {
        case .helloMesh: "N agents discover each other and exchange agent cards"
        case .proposeAccept: "Alice proposes, Bob accepts"
        case .replay: "Mallory re-sends a frame Bob already accepted"
        case .reorder: "Out-of-order messages inside the replay window arrive once"
        case .replayWindow: "Replay-window edges and extreme sequence numbers remain bounded"
        case .stale: "Old messages are dropped at a fixed-clock age boundary"
        case .futureDated: "Future messages are dropped without poisoning replay state"
        case .senderMismatch: "Mallory relays Alice's envelope over her own link"
        case .impersonation: "The secure channel drops Mallory's forged Alice envelope and link identity"
        case .garbage: "Mallory sends bytes that are not an envelope"
        }
    }
}

/// What a scenario produced, for assertions and printing.
public struct ScenarioOutcome: Sendable {
    public let transcript: [LogEntry]
    /// Envelopes the target (Bob, or every agent for the mesh) accepted.
    public let accepted: [Envelope]
    /// Frames the target's Inbox dropped, after any secure channel.
    public let dropped: [InboxDrop]
    /// Additional frames rejected by the secure channel during the attack.
    public let secureDroppedFrames: Int
    /// Peer whose key the target's secure channel still proves after the attack.
    public let provenPeer: PeerID?

    init(transcript: [LogEntry], accepted: [Envelope], dropped: [InboxDrop],
         secureDroppedFrames: Int = 0, provenPeer: PeerID? = nil) {
        self.transcript = transcript
        self.accepted = accepted
        self.dropped = dropped
        self.secureDroppedFrames = secureDroppedFrames
        self.provenPeer = provenPeer
    }
}

public enum ScenarioRunner {
    static let now = Date(timeIntervalSince1970: 1_790_967_600)

    public static func run(_ scenario: Scenario, agents: Int = 3) async throws -> ScenarioOutcome {
        let simulation = Simulation(seed: 42, now: { now },
                                    security: scenario == .impersonation ? .secureChannel : .none)
        do {
            let result = try await run(scenario, simulation: simulation, agents: agents)
            await simulation.stop()
            return result
        } catch {
            await simulation.stop()
            throw error
        }
    }

    private static func run(_ scenario: Scenario, simulation: Simulation, agents: Int) async throws -> ScenarioOutcome {
        switch scenario {
        case .helloMesh: try await helloMesh(simulation, count: agents)
        case .proposeAccept: try await proposeAccept(simulation)
        case .replay: try await replay(simulation)
        case .reorder, .replayWindow, .stale, .futureDated: try await temporal(scenario, simulation: simulation)
        case .senderMismatch: try await senderMismatch(simulation)
        case .impersonation: try await impersonation(simulation)
        case .garbage: try await garbage(simulation)
        }
    }

    static func helloMesh(_ simulation: Simulation, count: Int) async throws -> ScenarioOutcome {
        for index in 0..<count { try await simulation.addAgent("agent\(index)") }
        try await simulation.waitForMesh()
        var accepted: [Envelope] = []
        for agent in await simulation.agents { accepted += await agent.received }
        return ScenarioOutcome(transcript: await simulation.transcript(), accepted: accepted, dropped: [])
    }

    static func proposeAccept(_ simulation: Simulation) async throws -> ScenarioOutcome {
        let alice = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob", behavior: AcceptEverything())
        try await simulation.waitForMesh()

        let terms = try Terms([.activity: .keywords([try Keyword("boba")])])
        try await alice.send(.propose(try Proposal(round: 0, terms: terms)), to: bob.id)
        try await Simulation.eventually("alice receives accept") {
            await alice.received.contains { $0.body.kind == .accept }
        }
        return try await outcome(simulation, target: alice)
    }

    static func replay(_ simulation: Simulation) async throws -> ScenarioOutcome {
        let deliveries = await simulation.hub.deliveries()
        let alice = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob")
        try await simulation.waitForMesh()

        let terms = try Terms([.budget: .amount(try MoneyAmount(minorUnits: 1500))])
        let sent = try await alice.send(.propose(try Proposal(round: 0, terms: terms)), to: bob.id)
        let captured = try await firstDelivery(in: deliveries) { delivery in
            (try? EnvelopeCodec().decode(delivery.frame.bytes))?.id == sent.id
        }
        try await simulation.hub.inject(captured.frame, claimedSender: alice.id, to: bob.id)
        try await Simulation.eventually("bob drops the replay") { await !bob.dropped.isEmpty }
        return try await outcome(simulation, target: bob)
    }

    static func senderMismatch(_ simulation: Simulation) async throws -> ScenarioOutcome {
        let alice = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob")
        try await simulation.waitForMesh()

        let mallory = PeerID.random()
        let forged = try Envelope(
            conversation: ConversationID(), sender: alice.id, recipient: bob.id,
            sequence: 1_000, sentAt: Timestamp(now),
            body: .reject(Rejection(proposal: MessageID(), reason: .declinedByOwner))
        )
        try await simulation.hub.inject(Frame(EnvelopeCodec().encode(forged)), claimedSender: mallory, to: bob.id)
        try await Simulation.eventually("bob drops the relayed envelope") { await !bob.dropped.isEmpty }
        return try await outcome(simulation, target: bob)
    }

    static func impersonation(_ simulation: Simulation) async throws -> ScenarioOutcome {
        let alice = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob")
        try await simulation.waitForMesh()
        let droppedBefore = await bob.secureTransport?.status(of: alice.id).droppedFrames ?? 0

        let forged = try Envelope(
            conversation: ConversationID(), sender: alice.id, recipient: bob.id,
            sequence: 0, sentAt: Timestamp(now),
            body: .reject(Rejection(proposal: MessageID(), reason: .declinedByOwner))
        )
        try await simulation.hub.inject(Frame(EnvelopeCodec().encode(forged)), claimedSender: alice.id, to: bob.id)
        try await Simulation.eventually("bob's secure channel drops the forgery") {
            let dropped = await bob.secureTransport?.status(of: alice.id).droppedFrames ?? 0
            return dropped > droppedBefore
        }

        // Positive control: the real Alice can still send on the same session.
        // Reuse the forged conversation and sequence so accepting the forgery
        // would also poison Inbox replay state and block this genuine message.
        let terms = try Terms([.activity: .keywords([try Keyword("boba")])])
        let genuine = try await alice.send(.propose(try Proposal(round: 0, terms: terms)),
                                           to: bob.id, conversation: forged.conversation)
        try await Simulation.eventually("bob receives Alice's genuine proposal") {
            await bob.received.contains { $0.id == genuine.id }
        }
        let status = await bob.secureTransport?.status(of: alice.id)
        return ScenarioOutcome(
            transcript: await simulation.transcript(), accepted: await bob.received, dropped: await bob.dropped,
            secureDroppedFrames: (status?.droppedFrames ?? 0) - droppedBefore,
            provenPeer: status?.provenKey?.peerID
        )
    }

    static func garbage(_ simulation: Simulation) async throws -> ScenarioOutcome {
        _ = try await simulation.addAgent("alice")
        let bob = try await simulation.addAgent("bob")
        try await simulation.waitForMesh()
        try await simulation.hub.inject(Frame(Data("{\"not\":\"an envelope\"}".utf8)), claimedSender: PeerID.random(), to: bob.id)
        try await Simulation.eventually("bob drops garbage") { await !bob.dropped.isEmpty }
        return try await outcome(simulation, target: bob)
    }

    private static func outcome(_ simulation: Simulation, target: SimulatedAgent) async throws -> ScenarioOutcome {
        ScenarioOutcome(transcript: await simulation.transcript(), accepted: await target.received, dropped: await target.dropped)
    }

    private static func firstDelivery(
        in deliveries: AsyncStream<LoopbackHub.Delivery>,
        where predicate: @Sendable (LoopbackHub.Delivery) -> Bool
    ) async throws -> LoopbackHub.Delivery {
        for await delivery in deliveries where predicate(delivery) { return delivery }
        throw SimulationError.timedOut("delivery")
    }
}
