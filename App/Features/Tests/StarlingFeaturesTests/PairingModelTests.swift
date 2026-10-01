import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// A directory over scripted sessions, recording what the model asks for.
final class ScriptedDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [(PeerID, String)] = []
    private var finished: [PairedPeer] = []
    let candidates: [PairingCandidate]
    let makeSession: @Sendable (PairingCandidate, String) async throws -> any PairingSession

    init(candidates: [PairingCandidate], makeSession: @escaping @Sendable (PairingCandidate, String) async throws -> any PairingSession) {
        self.candidates = candidates
        self.makeSession = makeSession
    }

    var starts: [(PeerID, String)] { lock.withLock { started } }
    var paired: [PairedPeer] { lock.withLock { finished } }

    var directory: PairingDirectory {
        PairingDirectory(
            localPeer: PeerID.random(),
            candidates: { [candidates] in candidates },
            pair: { [self] candidate, nickname in
                lock.withLock { started.append((candidate.peer, nickname)) }
                return try await makeSession(candidate, nickname)
            },
            paired: { [self] peer in lock.withLock { finished.append(peer) } }
        )
    }
}

@MainActor
func readyToPair(_ model: PairingModel) async {
    await model.refreshCandidates()
    model.selected = model.candidates.first
    model.nickname = "Maya"
}

@MainActor
@Suite struct PairingModelTests {
    static let maya = Fixtures.peer("Phone")
    static let candidate = PairingCandidate(peer: maya.id, link: "Wi-Fi Aware")

    static func scripted(code: String = "482 913") -> ScriptedDirectory {
        let peer = maya
        return ScriptedDirectory(candidates: [candidate]) { _, nickname in
            ScriptedPairingSession(code: code, peer: try PairedPeer(publicKey: peer.publicKey, nickname: nickname, pairedAt: peer.pairedAt))
        }
    }

    @Test func listsNearbyPhonesAndNeedsAChoiceAndANameFirst() async {
        let model = PairingModel(directory: Self.scripted().directory)
        await model.refreshCandidates()
        #expect(model.candidates == [Self.candidate])
        #expect(!model.canStart)
        model.selected = Self.candidate
        #expect(!model.canStart, "a nickname is needed before the ceremony (lane E1 saves it with the pin)")
        model.nickname = "Maya"
        #expect(model.canStart)
    }

    @Test func showsTheCodeThenFinishesWithTheNamedFriend() async throws {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await readyToPair(model)

        await model.start()
        await eventually { model.phase == .comparing(code: "482 913") }
        #expect(model.phase == .comparing(code: "482 913"))
        #expect(directory.starts.map(\.1) == ["Maya"])

        await model.confirm(codesMatch: true)
        await eventually { if case .paired = model.phase { true } else { false } }
        guard case .paired(let peer) = model.phase else { Issue.record("expected paired"); return }
        #expect(peer.nickname == "Maya")
        #expect(directory.paired.map(\.id) == [Self.maya.id], "the app reconnects the links after pairing")
    }

    @Test func mismatchedCodesFailAndFinishNothing() async throws {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await readyToPair(model)
        await model.start()
        await eventually { if case .comparing = model.phase { true } else { false } }

        await model.confirm(codesMatch: false)
        await eventually { if case .failed = model.phase { true } else { false } }

        #expect(model.phase == .failed(.codeMismatch))
        #expect(directory.paired.isEmpty)
    }

    @Test func cancelEndsTheCeremony() async throws {
        let model = PairingModel(directory: Self.scripted().directory)
        await readyToPair(model)
        await model.start()
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.cancel()
        await eventually { if case .failed = model.phase { true } else { false } }
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func confirmIsIgnoredBeforeACodeIsShown() async {
        let model = PairingModel(directory: Self.scripted().directory)
        await model.confirm(codesMatch: true)
        #expect(model.phase == .idle)
    }

    @Test func anInvalidNicknameIsRefusedBeforeTheCeremony() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await readyToPair(model)
        model.nickname = "   "
        #expect(!model.canStart)
        await model.start()
        #expect(model.phase == .idle)
        #expect(directory.starts.isEmpty)
    }

    @Test func aFailureToStartIsReported() async {
        struct NoLink: Error {}
        let directory = ScriptedDirectory(candidates: [Self.candidate]) { _, _ in throw NoLink() }
        let model = PairingModel(directory: directory.directory)
        await readyToPair(model)
        await model.start()
        #expect(model.phase == .failed(.transportFailed))
    }

    /// Lane E2's WiFiAwareTransport.peerID(for:waitingUpTo:) (PR #38): the
    /// phone picked in the system's device picker becomes the one to pair.
    @Test func aPickedDeviceIsSelectedByItsPeerIDWithItsNameSuggested() async {
        let peer = PeerID.random()
        var directory = Self.scripted().directory
        directory.peerForPickedDevice = { id in id == 42 ? peer : nil }
        let model = PairingModel(directory: directory)
        await model.refreshCandidates()

        await model.pickedDevice(id: 42, name: "Maya's iPhone")
        #expect(model.selected?.peer == peer)
        #expect(model.selected?.link == "Wi-Fi Aware")
        #expect(model.candidates.contains { $0.peer == peer })
        // Issue #46: the other phone's own name is offered, never filled in.
        #expect(model.nickname.isEmpty)
        #expect(model.suggestedName == "Maya's iPhone")
        #expect(!model.canStart)
        model.useSuggestedName()
        #expect(model.nickname == "Maya's iPhone")

        model.nickname = "Maya"
        await model.pickedDevice(id: 42, name: "Maya's iPhone")
        #expect(model.nickname == "Maya", "an owner's own name is not replaced")
    }

    @Test func aPickedDeviceThatNeverSaysHelloIsReported() async {
        var directory = Self.scripted().directory
        directory.peerForPickedDevice = { _ in nil }
        let model = PairingModel(directory: directory)
        await model.pickedDevice(id: 7, name: "Phone")
        #expect(model.selected == nil)
        #expect(model.notice != nil)
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
        let model = PairingModel(directory: ScriptedDirectory(candidates: [PairingModelTests.candidate]) { _, _ in session }.directory)
        await readyToPair(model)
        await model.start()
        await eventually { model.phase == .comparing(code: "123 456") }

        await model.end()

        #expect(await session.cancels == 1)
        await eventually { model.phase == .failed(.cancelled) }
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func endingWhileTheSessionIsStillStartingCancelsItOnArrival() async {
        let session = CountingSession()
        let model = PairingModel(directory: ScriptedDirectory(candidates: [PairingModelTests.candidate]) { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return session
        }.directory)
        await readyToPair(model)
        let starting = Task { await model.start() }
        await eventually { model.phase == .starting }

        await model.end()
        await starting.value

        #expect(await session.cancels == 1)
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func endingAfterPairingChangesNothing() async throws {
        let directory = PairingModelTests.scripted(code: "1")
        let model = PairingModel(directory: directory.directory)
        await readyToPair(model)
        await model.start()
        await eventually { model.phase == .comparing(code: "1") }
        await model.confirm(codesMatch: true)
        await eventually { if case .paired = model.phase { true } else { false } }
        let paired = model.phase

        await model.end()
        #expect(model.phase == paired)
        #expect(directory.paired.count == 1)
    }
}

/// Records unpairs and renames the way the app's real functions would.
final class FriendActions: @unchecked Sendable {
    private let lock = NSLock()
    private var unpaired: [PeerID] = []
    var unpairs: [PeerID] { lock.withLock { unpaired } }
    let fails: Bool
    let store: InMemoryPairedPeerStore

    init(store: InMemoryPairedPeerStore, fails: Bool = false) {
        self.store = store
        self.fails = fails
    }

    struct Failure: Error {}

    /// Like lane E1's PinAuthority.unpair: removes the pin, or throws.
    var unpair: @Sendable (PeerID) async throws -> Void {
        { [self] id in
            if fails { throw Failure() }
            lock.withLock { unpaired.append(id) }
            try await store.remove(id)
        }
    }
}

@MainActor
@Suite struct FriendsModelTests {
    @Test func unpairsThroughTheAppsUnpairNotTheStore() async throws {
        let maya = Fixtures.peer("Maya", pairedAt: 1)
        let sam = Fixtures.peer("Sam", pairedAt: 2)
        let store = InMemoryPairedPeerStore([maya, sam])
        let actions = FriendActions(store: store)
        let model = FriendsModel(store: store, unpair: actions.unpair)

        await model.load()
        #expect(model.friends.map(\.nickname) == ["Maya", "Sam"])
        await model.remove(sam.id)
        #expect(actions.unpairs == [sam.id])
        #expect(model.friends.map(\.id) == [maya.id])
    }

    @Test func renamingIsOfferedOnlyWhenTheBuildCanDoItSafely() async {
        let maya = Fixtures.peer("Maya")
        let store = InMemoryPairedPeerStore([maya])
        let withoutRename = FriendsModel(store: store, unpair: FriendActions(store: store).unpair)
        #expect(!withoutRename.canRename)
        await withoutRename.load()
        #expect(await withoutRename.rename(maya.id, to: "M") == false)
        #expect(withoutRename.friends.first?.nickname == "Maya")

        let withRename = FriendsModel(store: store, unpair: FriendActions(store: store).unpair, rename: { id, name in
            guard let peer = try await store.peer(for: id) else { return }
            try await store.save(try PairedPeer(publicKey: peer.publicKey, nickname: name, pairedAt: peer.pairedAt))
        })
        #expect(withRename.canRename)
        await withRename.load()
        #expect(await withRename.rename(maya.id, to: "Maya R"))
        #expect(withRename.friends.first?.nickname == "Maya R")
        #expect(await withRename.rename(maya.id, to: "") == false)
        #expect(withRename.notice != nil)
    }

    @Test func tracksWhichFriendsAreReachable() async {
        let maya = Fixtures.peer("Maya")
        let store = InMemoryPairedPeerStore([maya])
        let model = FriendsModel(store: store, unpair: FriendActions(store: store).unpair)
        await model.load()
        model.handle(.peerAvailable(maya.id))
        #expect(model.isReachable(maya.id))
        model.handle(.peerUnavailable(maya.id))
        #expect(!model.isReachable(maya.id))
    }
}

/// Re-review finding 3 on PR #15: a failed unpair must stay visible, or the
/// owner believes a still-trusted friend is gone.
@MainActor
@Suite struct UnpairFailureTests {
    @Test func aFailedUnpairStaysOnScreenAfterTheListRefreshes() async {
        let maya = Fixtures.peer("Maya")
        let store = InMemoryPairedPeerStore([maya])
        let model = FriendsModel(store: store, unpair: FriendActions(store: store, fails: true).unpair)
        await model.load()

        await model.remove(maya.id)

        #expect(model.friends.map(\.id) == [maya.id], "still paired")
        #expect(model.notice?.contains("Maya") == true)
        #expect(model.notice?.contains("still paired") == true)
    }
}
