import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import Testing

/// Issue #40: revocation notices are delivered in tasks that are never
/// awaited (issue #32). With an observer that stalls, every revocation used
/// to add another suspended task, without bound. Pending notices must
/// coalesce per observer and peer, keeping the latest epoch.
@Suite struct NotificationBoundTests {
    actor Deliveries {
        private(set) var all: [(PeerID, UInt64)] = []
        func record(_ peer: PeerID, _ epoch: UInt64) { all.append((peer, epoch)) }
        func latest(for peer: PeerID) -> UInt64? { all.last { $0.0 == peer }?.1 }
    }

    @Test func aStalledObserverHoldsOneTaskAndGetsTheLatestEpochs() async throws {
        let authority = PinAuthority(identity: .generate(), store: InMemoryPairedPeerStore())
        let gate = Gate()
        let deliveries = Deliveries()
        authority.observeRevocations { peer, epoch in
            await gate.wait()
            await deliveries.record(peer, epoch)
        }

        let peers = (0..<5).map { _ in PeerID.random() }
        let revocations = 200
        for round in 0..<revocations {
            await authority.revoke(peers[round % peers.count])
        }
        try await eventually("the observer is stalled") { await gate.waiters >= 1 }
        try await settle()
        #expect(await gate.waiters == 1, "a stalled observer must hold one suspended delivery, not one per revocation")
        #expect(authority.pendingNoticeCount <= peers.count, "at most one pending notice per peer")

        await gate.release()
        try await eventually("every peer's latest epoch is delivered") {
            for peer in peers where await deliveries.latest(for: peer) != authority.epoch(of: peer) { return false }
            return true
        }
        try await settle()
        // The first notice was already in flight; after it, at most one
        // coalesced notice per peer.
        #expect(await deliveries.all.count <= 1 + peers.count)
    }
}
