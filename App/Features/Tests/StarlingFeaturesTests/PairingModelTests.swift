import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct PairingModelTests {
    func model(peer: PairedPeer, store: InMemoryPairedPeerStore) -> PairingModel {
        PairingModel(makeSession: { ScriptedPairingSession(code: "482 913", peer: peer) }, store: store)
    }

    func settle(_ model: PairingModel, until predicate: (PairingModel.Phase) -> Bool) async {
        await eventually { predicate(model.phase) }
    }

    @Test func showsTheCodeThenNamesAndSavesTheFriend() async throws {
        let store = InMemoryPairedPeerStore()
        let maya = Fixtures.peer("Phone")
        let model = model(peer: maya, store: store)

        await model.start()
        await settle(model) { $0 == .comparing(code: "482 913") }
        #expect(model.phase == .comparing(code: "482 913"))

        await model.confirm(codesMatch: true)
        await settle(model) { if case .naming = $0 { true } else { false } }
        #expect(model.phase == .naming(maya))
        #expect(model.nickname == "Phone")

        model.nickname = "Maya"
        await model.saveNickname()

        let saved = try #require(try await store.peer(for: maya.id))
        #expect(saved.nickname == "Maya")
        #expect(model.phase == .paired(saved))
    }

    @Test func mismatchedCodesFailAndSaveNothing() async throws {
        let store = InMemoryPairedPeerStore()
        let model = model(peer: Fixtures.peer("Maya"), store: store)
        await model.start()
        await settle(model) { if case .comparing = $0 { true } else { false } }

        await model.confirm(codesMatch: false)
        await settle(model) { if case .failed = $0 { true } else { false } }

        #expect(model.phase == .failed(.codeMismatch))
        #expect(try await store.all().isEmpty)
    }

    @Test func cancelEndsTheCeremony() async throws {
        let model = model(peer: Fixtures.peer("Maya"), store: InMemoryPairedPeerStore())
        await model.start()
        await settle(model) { if case .comparing = $0 { true } else { false } }
        await model.cancel()
        await settle(model) { if case .failed = $0 { true } else { false } }
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func confirmIsIgnoredBeforeACodeIsShown() async {
        let model = model(peer: Fixtures.peer("Maya"), store: InMemoryPairedPeerStore())
        await model.confirm(codesMatch: true)
        #expect(model.phase == .idle)
    }

    @Test func invalidNicknameKeepsTheNamingStep() async throws {
        let store = InMemoryPairedPeerStore()
        let model = model(peer: Fixtures.peer("Maya"), store: store)
        await model.start()
        await settle(model) { if case .comparing = $0 { true } else { false } }
        await model.confirm(codesMatch: true)
        await settle(model) { if case .naming = $0 { true } else { false } }

        model.nickname = "   "
        await model.saveNickname()

        guard case .naming = model.phase else { Issue.record("expected naming, got \(model.phase)"); return }
        #expect(model.notice != nil)
        #expect(try await store.all().isEmpty)
    }

    @Test func factoryFailureIsReported() async {
        struct NoLink: Error {}
        let model = PairingModel(makeSession: { throw NoLink() }, store: InMemoryPairedPeerStore())
        await model.start()
        #expect(model.phase == .failed(.transportFailed))
    }

    @Test func everyFailureHasAMessage() {
        for failure in [PairingFailure.codeMismatch, .cancelled, .timedOut, .transportFailed, .protocolError] {
            #expect(!PairingModel.message(for: failure).isEmpty)
        }
    }
}

/// Review finding 5 on PR #15: when the pairing sheet goes away, the
/// ceremony stops instead of running on with no screen.
@MainActor
@Suite struct PairingEndTests {
    /// Counts cancels and otherwise behaves like ScriptedPairingSession.
    actor CountingSession: PairingSession {
        nonisolated let events: AsyncStream<PairingEvent>
        private let continuation: AsyncStream<PairingEvent>.Continuation
        private(set) var cancels = 0

        init() {
            (events, continuation) = AsyncStream.makeStream(of: PairingEvent.self)
            continuation.yield(.confirmCode("123 456"))
        }

        func confirm(codesMatch: Bool) async {}

        func cancel() async {
            cancels += 1
            continuation.yield(.failed(.cancelled))
            continuation.finish()
        }
    }

    @Test func endingWhileComparingCancelsTheCeremony() async {
        let session = CountingSession()
        let model = PairingModel(makeSession: { session }, store: InMemoryPairedPeerStore())
        await model.start()
        await eventually { model.phase == .comparing(code: "123 456") }

        await model.end()

        #expect(await session.cancels == 1)
        await eventually { model.phase == .failed(.cancelled) }
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func endingWhileTheSessionIsStillStartingCancelsItOnArrival() async {
        let session = CountingSession()
        let model = PairingModel(makeSession: {
            try await Task.sleep(for: .milliseconds(50))
            return session
        }, store: InMemoryPairedPeerStore())
        let starting = Task { await model.start() }
        await eventually { model.phase == .starting }

        await model.end()
        await starting.value

        #expect(await session.cancels == 1)
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func endingAfterPairingChangesNothing() async throws {
        let store = InMemoryPairedPeerStore()
        let peer = Fixtures.peer("Maya")
        let model = PairingModel(makeSession: { ScriptedPairingSession(code: "1", peer: peer) }, store: store)
        await model.start()
        await eventually { model.phase == .comparing(code: "1") }
        await model.confirm(codesMatch: true)
        await eventually { if case .naming = model.phase { true } else { false } }
        await model.saveNickname()
        let paired = model.phase

        await model.end()
        #expect(model.phase == paired)
        #expect(try await store.all().count == 1)
    }
}

@MainActor
@Suite struct FriendsModelTests {
    @Test func listsRenamesAndRemovesFriends() async throws {
        let maya = Fixtures.peer("Maya", pairedAt: 1)
        let sam = Fixtures.peer("Sam", pairedAt: 2)
        let store = InMemoryPairedPeerStore([maya, sam])
        let model = FriendsModel(store: store)

        await model.load()
        #expect(model.friends.map(\.nickname) == ["Maya", "Sam"])

        #expect(await model.rename(maya.id, to: "Maya R"))
        #expect(model.friends.first?.nickname == "Maya R")
        #expect(try await store.peer(for: maya.id)?.publicKey == maya.publicKey)

        await model.remove(sam.id)
        #expect(model.friends.map(\.id) == [maya.id])
    }

    @Test func rejectsAnEmptyNickname() async {
        let maya = Fixtures.peer("Maya")
        let model = FriendsModel(store: InMemoryPairedPeerStore([maya]))
        await model.load()
        #expect(await model.rename(maya.id, to: "") == false)
        #expect(model.notice != nil)
        #expect(model.friends.first?.nickname == "Maya")
    }
}
