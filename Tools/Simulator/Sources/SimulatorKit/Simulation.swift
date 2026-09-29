import Foundation
import StarlingCore
import StarlingFakes
import StarlingTransport

public enum SimulationError: Error {
    case timedOut(String)
}

/// N simulated agents on one Loopback hub.
public actor Simulation {
    public nonisolated let hub: LoopbackHub
    public private(set) var agents: [SimulatedAgent] = []
    private var generator: SeededPeerGenerator
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - seed: Makes peer IDs, and so every transcript, reproducible.
    ///   - now: Clock shared by all agents.
    public init(seed: UInt64 = 1, latency: Duration = .zero, now: @escaping @Sendable () -> Date = { Date() }) {
        hub = LoopbackHub(latency: latency)
        generator = SeededPeerGenerator(seed: seed)
        self.now = now
    }

    @discardableResult
    public func addAgent(
        _ name: String,
        behavior: any AgentBehavior = PassiveBehavior(),
        model: ModelLocality = .onDevice,
        policy: any PolicyEngine = FixedPolicyEngine(.allow),
        consent: any ConsentProvider = ScriptedConsentProvider(.approved)
    ) async throws -> SimulatedAgent {
        let card = try AgentCard(model: model, capabilities: [.down])
        let agent = SimulatedAgent(
            name: name,
            id: PeerID.random(using: &generator),
            hub: hub,
            card: card,
            behavior: behavior,
            policy: policy,
            consent: consent,
            now: now
        )
        agents.append(agent)
        try await agent.start()
        return agent
    }

    /// Waits until every agent has every other agent's card.
    public func waitForMesh(timeout: Duration = .seconds(5)) async throws {
        let expected = agents.count - 1
        let agents = agents
        try await Self.eventually(timeout: timeout, "mesh of \(agents.count)") {
            for agent in agents where await agent.peerCards.count < expected { return false }
            return true
        }
    }

    public func stop() async {
        for agent in agents { await agent.stop() }
    }

    /// Every agent's log, agent by agent, in insertion order.
    public func transcript() async -> [LogEntry] {
        var lines: [LogEntry] = []
        for agent in agents { lines += await agent.log }
        return lines
    }

    /// Polls `condition` until it holds or `timeout` passes.
    public static func eventually(
        timeout: Duration = .seconds(5),
        _ what: String,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SimulationError.timedOut(what)
    }
}

/// SplitMix64 so seeded simulations give the same peer IDs every run.
struct SeededPeerGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
