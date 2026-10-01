import Foundation
import StarlingCore
import StarlingFakes
import StarlingIdentity
import StarlingTransport

public enum SimulationError: Error {
    case timedOut(String)
}

/// How simulated agents' links are protected.
public enum LinkSecurity: Sendable {
    /// Bare Loopback, as in Phase 0: a link's claimed peer ID is believed.
    case none
    /// Each agent has its own identity key and runs lane E1's
    /// `SecureTransport` over Loopback, and every two agents are pinned to
    /// each other as if they had paired in person (ADR 0003). Peer IDs come
    /// from random keys, so they differ from run to run.
    case secureChannel
}

/// N simulated agents on one Loopback hub.
public actor Simulation {
    public nonisolated let hub: LoopbackHub
    public nonisolated let security: LinkSecurity
    public private(set) var agents: [SimulatedAgent] = []
    private var generator: SeededPeerGenerator
    private let now: @Sendable () -> Date
    /// Each secure agent's pinned friends, keyed by its peer ID.
    private var pinStores: [PeerID: InMemoryPairedPeerStore] = [:]
    private var publicKeys: [PeerID: (name: String, key: IdentityPublicKey)] = [:]

    /// - Parameters:
    ///   - seed: Makes peer IDs, and so every transcript, reproducible
    ///     (bare Loopback only; see `LinkSecurity.secureChannel`).
    ///   - now: Clock shared by all agents.
    ///   - security: Bare Loopback by default.
    public init(
        seed: UInt64 = 1,
        latency: Duration = .zero,
        now: @escaping @Sendable () -> Date = { Date() },
        security: LinkSecurity = .none
    ) {
        hub = LoopbackHub(latency: latency)
        generator = SeededPeerGenerator(seed: seed)
        self.now = now
        self.security = security
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
        let agent: SimulatedAgent
        switch security {
        case .none:
            agent = SimulatedAgent(
                name: name,
                transport: LoopbackTransport(localPeer: PeerID.random(using: &generator), hub: hub),
                card: card,
                behavior: behavior,
                policy: policy,
                consent: consent,
                now: now
            )
        case .secureChannel:
            let secure = try await makeSecureTransport(name)
            agent = SimulatedAgent(
                name: name,
                transport: secure,
                secureTransport: secure,
                card: card,
                behavior: behavior,
                policy: policy,
                consent: consent,
                now: now
            )
        }
        agents.append(agent)
        try await agent.start()
        return agent
    }

    /// A new identity whose secure channel trusts every agent already here,
    /// and which every agent already here trusts. The pins are written
    /// before the newcomer's link comes up, so they stand in for a finished
    /// pairing ceremony; nothing else writes these stores.
    private func makeSecureTransport(_ name: String) async throws -> SecureTransport {
        let identity = IdentityKeyPair.generate()
        let pairedAt = Timestamp(now())
        let store = InMemoryPairedPeerStore()
        for (peer, other) in publicKeys {
            try await store.save(PairedPeer(publicKey: other.key, nickname: other.name, pairedAt: pairedAt))
            try await pinStores[peer]?.save(PairedPeer(publicKey: identity.publicKey, nickname: name, pairedAt: pairedAt))
        }
        pinStores[identity.peerID] = store
        publicKeys[identity.peerID] = (name, identity.publicKey)
        let link = LoopbackTransport(localPeer: identity.peerID, hub: hub)
        return SecureTransport(wrapping: link, authority: PinAuthority(identity: identity, store: store))
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
