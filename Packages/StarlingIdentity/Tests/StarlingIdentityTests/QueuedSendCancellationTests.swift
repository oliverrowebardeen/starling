import Foundation
import StarlingCore
@testable import StarlingIdentity
import StarlingTransport
import Testing

/// Review of PR #51: a withdrawn Swap photos offer queued behind a stalled
/// secure send still left the phone, because the queued send ran in its own
/// task and never saw the caller's cancellation.
@Suite struct QueuedSendCancellationTests {
    @Test func aCancelledSendQueuedBehindAStalledOneNeverLeaves() async throws {
        let aliceKey = IdentityKeyPair.generate()
        let bobKey = IdentityKeyPair.generate()
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], gated: true)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await eventually("both sessions confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }

        let link = try #require(alice.link as? GatedLink)
        await link.armSendGate()
        let first = Task { try await alice.secure.send(Frame(Data("first".utf8)), to: bob.id) }
        try await eventually("the first send is stalled on the link") { await link.suspendedSends == 1 }
        let withdrawn = Task { try await alice.secure.send(Frame(Data("withdrawn offer".utf8)), to: bob.id) }
        // Let the second send reach the queue behind the first, then withdraw it.
        try await Task.sleep(for: .milliseconds(50))
        withdrawn.cancel()

        // The withdrawn send waits its turn behind the stalled one, then
        // stops before sealing: it never reaches the link.
        await link.releaseSends()
        try await first.value
        await #expect(throws: CancellationError.self) { try await withdrawn.value }
        try await eventually("bob gets the first frame") { await bob.events.received.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await bob.events.received.map(\.0) == [Data("first".utf8)])
    }
}
