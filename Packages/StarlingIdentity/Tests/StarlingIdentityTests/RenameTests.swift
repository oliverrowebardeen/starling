import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

/// PinAuthority.rename: the only safe way to change a pinned friend's
/// nickname. It goes through the pin lock like commits and unpairs, so it
/// can never re-pin a friend the owner just unpaired.
@Suite struct RenameTests {
    let aliceKey = IdentityKeyPair.generate()
    let bobKey = IdentityKeyPair.generate()

    func connected() async throws -> (Node, Node) {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        return (alice, bob)
    }

    @Test func renameChangesOnlyTheNickname() async throws {
        let (alice, bob) = try await connected()
        let before = try #require(try await alice.store.peer(for: bob.id))
        try await alice.authority.rename(bob.id, to: "  Bobby ")
        let after = try #require(try await alice.store.peer(for: bob.id))
        #expect(after.nickname == "Bobby")
        #expect(after.publicKey == before.publicKey)
        #expect(after.id == before.id)
        #expect(after.pairedAt == before.pairedAt)
        // The session is untouched: a rename is not a revocation.
        try await bob.secure.send(Frame(Data("still here".utf8)), to: alice.id)
        try await alice.waitForMessages(1)
    }

    @Test func renameRefusesAPeerThatIsNotPinned() async throws {
        let (alice, _) = try await connected()
        let stranger = IdentityKeyPair.generate().peerID
        await #expect(throws: PinAuthorityError.notPinned) { try await alice.authority.rename(stranger, to: "Who") }
        #expect(try await alice.store.peer(for: stranger) == nil)
    }

    @Test func renameRefusesAnInvalidNickname() async throws {
        let (alice, bob) = try await connected()
        await #expect(throws: ValidationError.self) { try await alice.authority.rename(bob.id, to: "   ") }
        #expect(try await alice.store.peer(for: bob.id)?.nickname == "friend")
    }

    /// An unpair is removing the pin (held before its delete). A rename
    /// started now is refused, and the pin is gone once the unpair ends.
    @Test func renameRefusesAPeerBeingUnpaired() async throws {
        let (alice, bob) = try await connected()
        await alice.store.arm(.removeBeforeDelete)
        let unpair = Task { try await alice.secure.unpair(bob.id) }
        try await eventually("the unpair is removing the pin") { await alice.store.suspended(at: .removeBeforeDelete) == 1 }
        await #expect(throws: PinAuthorityError.unpairInProgress) { try await alice.authority.rename(bob.id, to: "Bobby") }
        await alice.store.release(.removeBeforeDelete)
        try await unpair.value
        #expect(try await alice.store.peer(for: bob.id) == nil)
    }

    /// A failed delete leaves the peer quarantined; renaming it is refused.
    @Test func renameRefusesAQuarantinedPeer() async throws {
        let (alice, bob) = try await connected()
        await alice.store.failRemovals(true)
        await #expect(throws: KeychainError.self) { try await alice.secure.unpair(bob.id) }
        #expect(alice.authority.isBlocked(bob.id))
        await #expect(throws: PinAuthorityError.quarantined) { try await alice.authority.rename(bob.id, to: "Bobby") }
    }

    /// The race lane H's direct save had: a rename is held mid-save when the
    /// owner unpairs. The unpair's delete waits for the rename to release the
    /// pin lock, then removes the pin, so the rename cannot bring it back.
    @Test func aRenameHeldMidSaveCannotOutliveAnUnpair() async throws {
        let (alice, bob) = try await connected()
        await alice.store.arm(.saveBeforeWrite)
        let rename = Task { try await alice.authority.rename(bob.id, to: "Bobby") }
        try await eventually("the rename is held before its write") { await alice.store.suspended(at: .saveBeforeWrite) == 1 }
        let unpair = Task { try await alice.secure.unpair(bob.id) }
        try await settle()
        await alice.store.release(.saveBeforeWrite)
        _ = try? await rename.value
        try await unpair.value
        #expect(try await alice.store.peer(for: bob.id) == nil)
        #expect(await alice.secure.status(of: bob.id).provenKey == nil)
    }

    /// The other order: the rename has read the pin (lookup held) when the
    /// unpair begins. The rename must not save.
    @Test func aRenameThatReadThePinBeforeAnUnpairDoesNotSave() async throws {
        let (alice, bob) = try await connected()
        await alice.store.armLookupGate()
        let rename = Task { try await alice.authority.rename(bob.id, to: "Bobby") }
        try await eventually("the rename has read the pin") { await alice.store.suspendedLookups == 1 }
        let unpair = Task { try await alice.secure.unpair(bob.id) }
        try await settle()
        await alice.store.releaseLookups()
        await #expect(throws: PinAuthorityError.unpairInProgress) { try await rename.value }
        try await unpair.value
        #expect(try await alice.store.peer(for: bob.id) == nil)
    }
}
