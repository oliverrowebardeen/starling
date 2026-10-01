import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import Testing

/// Review 3 finding 3: generation state is bounded, and evicting an entry
/// never lets a stale reading match again.
@Suite struct GenerationTableTests {
    @Test func staysWithinCapacity() {
        var table = GenerationTable(capacity: 8)
        for _ in 0..<1_000 { table.bump(.random()) }
        #expect(table.count == 8)
    }

    @Test func aReadingTakenBeforeAnEvictionNeverMatchesAfterIt() {
        var table = GenerationTable(capacity: 4)
        let bob = PeerID.random()
        let carol = PeerID.random()
        // Carol has never been bumped; Bob has.
        let carolBefore = table.value(of: carol)
        table.bump(bob)
        let bobBefore = table.value(of: bob)
        // Bob is revoked, then evicted by unrelated traffic.
        table.bump(bob)
        for _ in 0..<10 { table.bump(.random()) }
        #expect(table.value(of: bob) != bobBefore)
        #expect(table.value(of: carol) != carolBefore)
        // And a value is never handed out twice.
        #expect(table.value(of: bob) > bobBefore)
    }

    @Test func secureTransportGenerationsAndPinTokensAreBounded() async throws {
        let identity = IdentityKeyPair.generate()
        let link = RecordingTransport(localPeer: identity.peerID)
        let configuration = SecureTransportConfiguration(maxTrackedPeers: 16)
        let secure = SecureTransport(wrapping: link, identity: identity, pairedPeers: InMemoryPairedPeerStore(), configuration: configuration)
        try await secure.start()
        for _ in 0..<500 { await secure.disconnect(.random()) }
        #expect(await secure.trackedGenerationCount <= 16)
        #expect(secure.pins.trackedTokenCount <= 16)
    }
}
