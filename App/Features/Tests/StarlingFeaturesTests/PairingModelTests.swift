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
    private var renamed: [(PeerID, String)] = []
    private var asking: [PeerID] = []
    private var openCount = 0
    let candidates: [PairingCandidate]
    let deviceNames: [PeerID: String]
    let renameFails: Bool
    let makeSession: @Sendable (PeerID, String) async throws -> any PairingSession

    init(
        candidates: [PairingCandidate], deviceNames: [PeerID: String] = [:], renameFails: Bool = false,
        makeSession: @escaping @Sendable (PeerID, String) async throws -> any PairingSession
    ) {
        self.candidates = candidates
        self.deviceNames = deviceNames
        self.renameFails = renameFails
        self.makeSession = makeSession
    }

    var starts: [(PeerID, String)] { lock.withLock { started } }
    var paired: [PairedPeer] { lock.withLock { finished } }
    var renames: [(PeerID, String)] { lock.withLock { renamed } }
    var opens: Int { lock.withLock { openCount } }
    func ask(from peer: PeerID) { lock.withLock { asking = [peer] } }

    struct RenameFailed: Error {}

    var directory: PairingDirectory {
        PairingDirectory(
            localPeer: PeerID.random(),
            candidates: { [candidates] in candidates },
            requests: { [self] in lock.withLock { asking } },
            pair: { [self] peer, nickname in
                lock.withLock { started.append((peer, nickname)) }
                return try await makeSession(peer, nickname)
            },
            paired: { [self] peer in lock.withLock { finished.append(peer) } },
            rename: { [self] id, name in
                if renameFails { throw RenameFailed() }
                lock.withLock { renamed.append((id, name)) }
            },
            deviceName: { [deviceNames] id in deviceNames[id] },
            opened: { [self] in lock.withLock { openCount += 1 } }
        )
    }
}

/// Counts what the model asks of notifications.
@MainActor
final class OfferRecorder {
    var notAsked: Bool
    var asks = 0
    init(notAsked: Bool) { self.notAsked = notAsked }

    var offer: NotificationOffer {
        NotificationOffer(shouldOffer: { [self] in notAsked }, ask: { [self] in asks += 1; notAsked = false })
    }
}

@MainActor
@Suite struct PairingModelTests {
    static let maya = Fixtures.peer("Phone")
    static let candidate = PairingCandidate(peer: maya.id, deviceName: "Maya's iPhone")

    static func scripted(code: String = "482 913", deviceNames: [PeerID: String] = [:], renameFails: Bool = false) -> ScriptedDirectory {
        let peer = maya
        return ScriptedDirectory(candidates: [candidate], deviceNames: deviceNames, renameFails: renameFails) { _, nickname in
            ScriptedPairingSession(code: code, peer: try PairedPeer(publicKey: peer.publicKey, nickname: nickname, pairedAt: peer.pairedAt))
        }
    }

    func pairAndConfirm(_ model: PairingModel) async {
        await model.choose(Self.candidate)
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.confirm(codesMatch: true)
        await eventually { if case .naming = model.phase { true } else { false } }
    }

    @Test func listsNearbyPhonesByTheirNameOrShortID() async {
        let model = PairingModel(directory: Self.scripted().directory)
        await model.refresh()
        #expect(model.candidates == [Self.candidate])
        #expect(Self.candidate.label == "Maya's iPhone")
        #expect(PairingCandidate(peer: Self.maya.id).label == "Phone \(Self.maya.id.short)")
    }

    /// One tap on a phone starts the ceremony: no name first (issue #95).
    @Test func choosingAPhoneStartsAtOnceUnderAPlaceholderName() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await model.choose(Self.candidate)
        await eventually { model.phase == .comparing(code: "482 913") }
        #expect(model.phase == .comparing(code: "482 913"))
        #expect(directory.starts.map(\.0) == [Self.maya.id])
        #expect(directory.starts.map(\.1) == [PairingModel.placeholderName])
    }

    /// The other phone does not pick: it joins the phone that asked.
    @Test func aRequestFromAnotherPhoneIsJoined() async {
        let directory = Self.scripted(deviceNames: [Self.maya.id: "Maya's iPhone"])
        let model = PairingModel(directory: directory.directory)
        await model.refresh()
        #expect(directory.starts.isEmpty)
        directory.ask(from: Self.maya.id)
        await model.refresh()
        await eventually { if case .comparing = model.phase { true } else { false } }
        #expect(directory.starts.map(\.0) == [Self.maya.id])
        #expect(model.phone?.label == "Maya's iPhone")
    }

    /// One owner taps Try again; the other phone, still showing the
    /// failure, joins without a tap. A different phone's request does not
    /// pull it into another ceremony.
    @Test func aFailedSheetJoinsTheSamePhoneTryingAgain() async {
        let failing = ScriptedDirectory(candidates: [Self.candidate]) { _, _ in TimingOutSession() }
        let model = PairingModel(directory: failing.directory)
        await model.choose(Self.candidate)
        await eventually { model.phase == .failed(.timedOut) }
        failing.ask(from: PeerID.random())
        await model.refresh()
        #expect(model.phase == .failed(.timedOut))
        failing.ask(from: Self.maya.id)
        await model.refresh()
        #expect(failing.starts.count == 2)
    }

    /// Cancel and "They're different" stick: the sheet does not rejoin.
    @Test func aFailureThisOwnerChoseIsNotRejoined() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await model.choose(Self.candidate)
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.confirm(codesMatch: false)
        await eventually { if case .failed = model.phase { true } else { false } }
        directory.ask(from: Self.maya.id)
        await model.refresh()
        #expect(model.phase == .failed(.codeMismatch))
        #expect(directory.starts.count == 1)
    }

    actor TimingOutSession: PairingSession {
        nonisolated let events: AsyncStream<PairingEvent>
        init() {
            let (stream, continuation) = AsyncStream.makeStream(of: PairingEvent.self)
            continuation.yield(.failed(.timedOut))
            continuation.finish()
            events = stream
        }
        func confirm(codesMatch: Bool) async {}
        func cancel() async {}
    }

    @Test func requestsAreNotJoinedMidCeremony() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await model.choose(Self.candidate)
        await eventually { if case .comparing = model.phase { true } else { false } }
        directory.ask(from: PeerID.random())
        await model.refresh()
        #expect(directory.starts.count == 1)
    }

    /// After both confirm, the owner names the friend. The prefill is a
    /// first name read from the phone's name, never the device name.
    @Test func confirmingAsksForANamePrefilledFromThePhone() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await pairAndConfirm(model)
        #expect(model.name == "Maya")
        #expect(directory.paired.map(\.id) == [Self.maya.id], "the app reconnects the links after pairing")
        model.name = "Maya R"
        await model.saveName()
        #expect(directory.renames.map(\.1) == ["Maya R"])
        #expect(model.phase == .done)
    }

    @Test func aPhoneWithNoUsableNameLeavesTheFieldEmpty() async {
        let maya = Self.maya
        let directory = ScriptedDirectory(candidates: []) { _, nickname in
            ScriptedPairingSession(code: "1", peer: try PairedPeer(publicKey: maya.publicKey, nickname: nickname, pairedAt: maya.pairedAt))
        }
        let model = PairingModel(directory: directory.directory)
        await model.choose(PairingCandidate(peer: Self.maya.id, deviceName: "iPhone"))
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.confirm(codesMatch: true)
        await eventually { if case .naming = model.phase { true } else { false } }
        #expect(model.name.isEmpty)
        #expect(!model.canSaveName)
        await model.saveName()
        #expect(model.notice != nil)
        if case .naming = model.phase {} else { Issue.record("still naming") }
    }

    @Test func aFailedRenameStaysOnTheNameStep() async {
        let model = PairingModel(directory: Self.scripted(renameFails: true).directory)
        await pairAndConfirm(model)
        model.name = "Maya"
        await model.saveName()
        #expect(model.notice?.contains("couldn't save") == true)
        if case .naming = model.phase {} else { Issue.record("still naming") }
    }

    /// Oliver's request: after the first friend, one button leads straight
    /// to iOS's notification alert, and only while iOS has not asked.
    @Test func notificationsAreOfferedOnceAfterPairingWhileNotAsked() async {
        let recorder = OfferRecorder(notAsked: true)
        let model = PairingModel(directory: Self.scripted().directory, notifications: recorder.offer)
        await pairAndConfirm(model)
        await model.saveName()
        #expect(model.phase == .notifications(friend: "Maya"))
        await model.continueToNotifications()
        #expect(recorder.asks == 1)
        #expect(model.phase == .done)

        let again = PairingModel(directory: Self.scripted().directory, notifications: recorder.offer)
        await pairAndConfirm(again)
        await again.saveName()
        #expect(again.phase == .done, "iOS already asked")
        #expect(recorder.asks == 1)
    }

    @Test func mismatchedCodesFailAndFinishNothing() async throws {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await model.choose(Self.candidate)
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.confirm(codesMatch: false)
        await eventually { if case .failed = model.phase { true } else { false } }
        #expect(model.phase == .failed(.codeMismatch))
        #expect(directory.paired.isEmpty)
    }

    @Test func tryAgainStartsWithTheSamePhone() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await model.choose(Self.candidate)
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.cancel()
        await eventually { if case .failed = model.phase { true } else { false } }
        #expect(model.phase == .failed(.cancelled))
        await model.tryAgain()
        await eventually { if case .comparing = model.phase { true } else { false } }
        #expect(directory.starts.map(\.0) == [Self.maya.id, Self.maya.id])
    }

    @Test func confirmIsIgnoredBeforeACodeIsShown() async {
        let model = PairingModel(directory: Self.scripted().directory)
        await model.confirm(codesMatch: true)
        #expect(model.phase == .choosing)
    }

    @Test func aFailureToStartIsReported() async {
        struct NoLink: Error {}
        let directory = ScriptedDirectory(candidates: [Self.candidate]) { _, _ in throw NoLink() }
        let model = PairingModel(directory: directory.directory)
        await model.choose(Self.candidate)
        #expect(model.phase == .failed(.transportFailed))
    }

    /// The phone picked in the system's device picker is paired as soon as
    /// its link says hello, and its name labels the phone.
    @Test func aPickedDeviceStartsTheCeremonyWithItsPeerID() async {
        let directory = Self.scripted()
        var paths = directory.directory
        let maya = Self.maya.id
        paths.peerForPickedDevice = { id in id == 42 ? maya : nil }
        let model = PairingModel(directory: paths)
        await model.pickedDevice(id: 42, name: "Maya's iPhone")
        await eventually { if case .comparing = model.phase { true } else { false } }
        #expect(directory.starts.map(\.0) == [Self.maya.id])
        #expect(model.phone?.label == "Maya's iPhone")
    }

    @Test func aPickedDeviceThatNeverSaysHelloGoesBackToChoosing() async {
        var directory = Self.scripted().directory
        directory.peerForPickedDevice = { _ in nil }
        let model = PairingModel(directory: directory)
        await model.pickedDevice(id: 7, name: "Maya's iPhone")
        #expect(model.phase == .choosing)
        #expect(model.notice?.contains("Maya's iPhone") == true)
    }

    @Test func openingTellsTheLinks() async {
        let directory = Self.scripted()
        let model = PairingModel(directory: directory.directory)
        await model.opened()
        #expect(directory.opens == 1)
    }

    @Test func everyFailureHasAMessage() {
        for failure in [PairingFailure.codeMismatch, .cancelled, .timedOut, .transportFailed, .protocolError] {
            #expect(!PairingModel.message(for: failure).isEmpty)
            #expect(!PairingModel.message(for: failure).contains("\u{2014}"))
        }
    }
}

@Suite struct FriendNameSuggestionTests {
    @Test(arguments: [
        ("Riley's iPhone", "Riley"),
        ("Riley’s iPhone 17 Pro", "Riley"),
        ("Mary Ann's iPad", "Mary Ann"),
        ("James' iPhone", "James"),
        ("iPhone de Lucía", "Lucía"),
        ("iPhone von Jonas", "Jonas"),
        ("小明的iPhone", "小明"),
    ])
    func readsAFirstName(_ device: String, _ expected: String) {
        #expect(FriendNameSuggestion.from(deviceName: device) == expected)
    }

    @Test(arguments: ["iPhone", "iPhone 17", "Living Room", "", "   ", "'s iPhone", "123's iPhone"])
    func neverSuggestsADeviceName(_ device: String) {
        #expect(FriendNameSuggestion.from(deviceName: device) == nil)
    }

    @Test func isCappedToANickname() {
        let long = String(repeating: "a", count: 200) + "'s iPhone"
        #expect(FriendNameSuggestion.from(deviceName: long)?.count == PairedPeer.maxNicknameCharacters)
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
        await model.choose(PairingModelTests.candidate)
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
        let starting = Task { await model.choose(PairingModelTests.candidate) }
        await eventually { model.phase == .connecting }
        await model.end()
        await starting.value
        #expect(await session.cancels == 1)
        #expect(model.phase == .failed(.cancelled))
    }

    @Test func endingAfterPairingChangesNothing() async throws {
        let directory = PairingModelTests.scripted(code: "1")
        let model = PairingModel(directory: directory.directory)
        await model.choose(PairingModelTests.candidate)
        await eventually { model.phase == .comparing(code: "1") }
        await model.confirm(codesMatch: true)
        await eventually { if case .naming = model.phase { true } else { false } }
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

/// Oliver's request (ADR 0260): notifications are asked right after a
/// pairing, never at launch, and never again once iOS has an answer.
@MainActor
@Suite struct PairingNotificationTests {
    func pairAndName(_ model: PairingModel) async {
        await model.choose(PairingModelTests.candidate)
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.confirm(codesMatch: true)
        await eventually { if case .naming = model.phase { true } else { false } }
        await model.saveName()
    }

    @Test func launchAsksNothingAndThePairingSheetAsksOnce() async throws {
        let notifier = RecordingNotifier(allow: true, access: .notAsked)
        let app = AppModel(services: AppModelTests.services(notifier: notifier))
        await app.start()
        #expect(await notifier.authorizationRequests == 0)
        #expect(app.notificationAccess == .notAsked)

        let model = try #require(app.makePairing())
        await pairAndName(model)
        #expect(model.phase == .notifications(friend: "Maya"))
        #expect(await notifier.authorizationRequests == 0, "nothing until Continue")
        await model.continueToNotifications()
        #expect(await notifier.authorizationRequests == 1)
        #expect(app.notificationAccess == .allowed)
        #expect(app.settings.settings.notificationsOffered, "the request-time offer does not ask again")

        let second = try #require(app.makePairing())
        await pairAndName(second)
        #expect(second.phase == .done)
        #expect(await notifier.authorizationRequests == 1)
    }

    /// Declined in iOS: no explanation, and You can show its quiet line.
    @Test func aDeclineInIOSIsNotAskedAgain() async throws {
        let notifier = RecordingNotifier(allow: false, access: .denied)
        let app = AppModel(services: AppModelTests.services(notifier: notifier))
        await app.start()
        #expect(app.notificationAccess == .denied)
        let model = try #require(app.makePairing())
        await pairAndName(model)
        #expect(model.phase == .done)
        #expect(await notifier.authorizationRequests == 0)
    }
}
