import Foundation
import StarlingCore
@testable import StarlingWiFiAware
import Testing

/// Fixed roles per paired device (ADR 0260). The fake air models the
/// developer report behind them (FB21527009): two phones that both publish
/// and subscribe to each other never connect.
@Suite struct WiFiAwareRoleTests {
    private static func timing(slot: Duration) -> AwareTiming {
        AwareTiming(
            helloTimeout: .seconds(2),
            fallbackDelay: .milliseconds(150),
            retryDelay: { attempt in attempt <= 5 ? .milliseconds(20 * attempt) : nil },
            radioRestartDelay: { _ in .milliseconds(20) },
            roles: .fixed(slot: slot),
            tentativeRoleLifetime: .seconds(30)
        )
    }

    private actor Available {
        private(set) var peers: Set<PeerID> = []
        func add(_ peer: PeerID) { peers.insert(peer) }
    }

    private struct Phone {
        let name: String
        let peer: PeerID
        let roles: InMemoryAwareRoleStore
        let transport: WiFiAwareTransport
        let available = Available()

        init(_ name: String, air: FakeAir, timing: AwareTiming, roles: InMemoryAwareRoleStore = InMemoryAwareRoleStore(), peer: PeerID = .random()) async {
            self.name = name
            self.peer = peer
            self.roles = roles
            transport = WiFiAwareTransport(localPeer: peer, radio: await air.radio(for: name), timing: timing, roleStore: roles)
            let events = transport.events
            let available = available
            Task {
                for await event in events {
                    if case .peerAvailable(let peer) = event { await available.add(peer) }
                }
            }
        }

        func sees(_ other: Phone) async -> Bool { await available.peers.contains(other.peer) }
    }

    /// Whether both phones see each other within `timeout` of the host's
    /// awake time (`SuspendingClock`, as in ADR 0258), checking once more
    /// at the deadline.
    private func linked(_ a: Phone, _ b: Phone, within timeout: Duration = .seconds(30)) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await a.sees(b), await b.sees(a) { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        guard await a.sees(b) else { return false }
        return await b.sees(a)
    }

    /// The hazard itself: symmetric roles on a platform that breaks them.
    ///
    /// Condition-based, not a time window: the fake refuses a dial only once
    /// both phones publish and subscribe, so the phones stay out of range
    /// until both have started both, and the test then waits for every dial
    /// the retry policy allows (one on discovery and five retries each)
    /// before checking that none linked.
    @Test func symmetricRolesNeverLinkWhereThePlatformBreaksThem() async throws {
        let air = FakeAir()
        await air.setSymmetricLinksFail(true)
        await air.pair("a", "b")
        await air.setInRange("a", "b", false)
        var symmetric = Self.timing(slot: .seconds(60))
        symmetric.roles = .symmetric
        let a = await Phone("a", air: air, timing: symmetric)
        let b = await Phone("b", air: air, timing: symmetric)
        try await a.transport.start()
        try await b.transport.start()
        try await eventually {
            let ab = await air.roles(of: "a", toward: "b")
            let ba = await air.roles(of: "b", toward: "a")
            return ab.publishes && ab.subscribes && ba.publishes && ba.subscribes
        }

        await air.setInRange("a", "b", true)
        let allowed = 6
        try await eventually {
            let ab = await air.dials(from: "a", to: "b")
            let ba = await air.dials(from: "b", to: "a")
            return ab >= allowed && ba >= allowed
        }
        #expect(await !a.sees(b))
        #expect(await !b.sees(a))
        #expect(await air.openConnectionCount("a", "b") == 0)
        await a.transport.stop()
        await b.transport.stop()
    }

    /// The phone that picked subscribes, the discoverable one publishes, and
    /// once the hello names both peers they settle on the PeerID rule.
    @Test(arguments: [true, false])
    func thePickerSubscribesAndTheOtherPublishes(pickArrivesAtOnce: Bool) async throws {
        let air = FakeAir()
        await air.setSymmetricLinksFail(true)
        let a = await Phone("a", air: air, timing: Self.timing(slot: .seconds(60)))
        let b = await Phone("b", air: air, timing: Self.timing(slot: .seconds(60)))
        try await a.transport.start()
        try await b.transport.start()
        await a.transport.expectPairing()
        await b.transport.expectPairing()

        // B picks A in the system picker. The pairing and the picker's
        // callback can reach B in either order.
        if pickArrivesAtOnce {
            await air.pair("a", "b")
            let aOnB = try #require(await air.deviceID(of: "a", seenBy: "b"))
            await b.transport.pickedDevice(WiFiAwarePairedDevice(id: aOnB, name: "A's iPhone"))
        } else {
            await air.pair("a", "b")
            try await Task.sleep(for: .milliseconds(50))
            let aOnB = try #require(await air.deviceID(of: "a", seenBy: "b"))
            await b.transport.pickedDevice(WiFiAwarePairedDevice(id: aOnB, name: "A's iPhone"))
        }
        #expect(await linked(a, b))

        // Both settle on the PeerID rule: the greater ID subscribes.
        let aOnB = try #require(await air.deviceID(of: "a", seenBy: "b"))
        let bOnA = try #require(await air.deviceID(of: "b", seenBy: "a"))
        let (high, low) = a.peer > b.peer ? (a, b) : (b, a)
        try await eventually { a.roles.load()[bOnA] != nil && b.roles.load()[aOnB] != nil }
        #expect(high.roles.load().values.first == .subscriber)
        #expect(low.roles.load().values.first == .publisher)
        // Still linked under the settled roles, and never both roles at once.
        #expect(await linked(a, b))
        let aRoles = await air.roles(of: "a", toward: "b")
        #expect(!(aRoles.publishes && aRoles.subscribes))
        await a.transport.stop()
        await b.transport.stop()
    }

    /// Pairings made before fixed roles (or while Starling was closed) have
    /// no role on either phone. Random roles per slot still meet, then settle.
    @Test func phonesWithNoRolesMeetThroughRandomSlots() async throws {
        let air = FakeAir()
        await air.setSymmetricLinksFail(true)
        await air.pair("a", "b")
        let a = await Phone("a", air: air, timing: Self.timing(slot: .milliseconds(60)))
        let b = await Phone("b", air: air, timing: Self.timing(slot: .milliseconds(60)))
        try await a.transport.start()
        try await b.transport.start()
        #expect(await linked(a, b))
        try await eventually { !a.roles.load().isEmpty && !b.roles.load().isEmpty }
        await a.transport.stop()
        await b.transport.stop()
    }

    /// Settled roles survive a relaunch, so the phones link at once without
    /// waiting for a slot.
    @Test func settledRolesLinkAtOnceAfterARelaunch() async throws {
        let air = FakeAir()
        await air.setSymmetricLinksFail(true)
        await air.pair("a", "b")
        let (aPeer, bPeer) = { let x = PeerID.random(), y = PeerID.random(); return x < y ? (x, y) : (y, x) }()
        let bOnA = try #require(await air.deviceID(of: "b", seenBy: "a"))
        let aOnB = try #require(await air.deviceID(of: "a", seenBy: "b"))
        // A has the lower ID, so it publishes and B subscribes.
        let a = await Phone("a", air: air, timing: Self.timing(slot: .seconds(60)), roles: InMemoryAwareRoleStore([bOnA: .publisher]), peer: aPeer)
        let b = await Phone("b", air: air, timing: Self.timing(slot: .seconds(60)), roles: InMemoryAwareRoleStore([aOnB: .subscriber]), peer: bPeer)
        try await a.transport.start()
        try await b.transport.start()
        // At once: without the saved roles they would wait for a 60 s slot.
        #expect(await linked(a, b, within: .seconds(2)))
        #expect(await air.dials(from: "a", to: "b") == 0, "the publisher never dials")
        await a.transport.stop()
        await b.transport.stop()
    }

    /// A pairing role lapses if no link ever forms, so a wrong guess cannot
    /// strand a device: it falls back to random slots.
    @Test func aTentativeRoleLapsesWithoutALink() async throws {
        let air = FakeAir()
        var timing = Self.timing(slot: .milliseconds(50))
        timing.tentativeRoleLifetime = .milliseconds(100)
        let a = await Phone("a", air: air, timing: timing)
        try await a.transport.start()
        await a.transport.expectPairing()
        await air.pair("a", "b")
        let bOnA = try #require(await air.deviceID(of: "b", seenBy: "a"))
        try await eventually { await a.transport.role(for: bOnA) == .publisher }
        var sawSubscriber = false
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(30)
        while !sawSubscriber, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
            sawSubscriber = await a.transport.role(for: bOnA) == .subscriber
        }
        #expect(sawSubscriber, "after the lapse the role follows the random slots")
        await a.transport.stop()
    }
}

/// Polls until `condition` holds, for up to `timeout` of the host's awake
/// time (ADR 0258), checking once more at the deadline.
private func eventually(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async throws {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await clock.sleep(for: .milliseconds(10))
    }
    if await condition() { return }
    Issue.record("condition not met in time")
}
