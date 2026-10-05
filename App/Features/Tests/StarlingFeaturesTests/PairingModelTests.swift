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
        let clock = PairingClock()
        let model = PairingModel(directory: failing.directory, now: clock.now)
        await model.choose(Self.candidate)
        await eventually { model.phase == .failed(.timedOut) }
        clock.advance(PairingModel.rejoinDelay)
        failing.ask(from: PeerID.random())
        await model.refresh()
        #expect(model.phase == .failed(.timedOut))
        failing.ask(from: Self.maya.id)
        await model.refresh()
        #expect(failing.starts.count == 2)
    }

    /// Review of #104: the failure a rejoin follows stays on screen for a
    /// few seconds first, so the owner sees every ceremony that ended.
    @Test func aFailureStaysOnScreenBeforeTheRejoin() async {
        let failing = ScriptedDirectory(candidates: [Self.candidate]) { _, _ in TimingOutSession() }
        let clock = PairingClock()
        let model = PairingModel(directory: failing.directory, now: clock.now)
        await model.choose(Self.candidate)
        await eventually { model.phase == .failed(.timedOut) }
        failing.ask(from: Self.maya.id)

        await model.refresh()
        clock.advance(PairingModel.rejoinDelay - 0.5)
        await model.refresh()
        #expect(failing.starts.count == 1, "not while the failure is new")
        #expect(model.phase == .failed(.timedOut))

        clock.advance(0.5)
        await model.refresh()
        #expect(failing.starts.count == 2, "then the one automatic rejoin")
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

/// Codex privacy review of PR #104 (HIGH): Cancel must invalidate a pairing
/// whose session is still being created, or a later attempt's confirm can
/// reach the wrong session and pin a key whose code was never compared.
@MainActor
@Suite struct PairingAttemptTests {
    /// A session the test drives: it shows codes on demand and records
    /// confirms and cancels.
    actor ControlledSession: PairingSession {
        nonisolated let events: AsyncStream<PairingEvent>
        private let continuation: AsyncStream<PairingEvent>.Continuation
        private(set) var confirms: [Bool] = []
        private(set) var cancels = 0

        init() { (events, continuation) = AsyncStream.makeStream(of: PairingEvent.self) }

        /// When set, `cancel()` waits here until released.
        var cancelGate: Gate?

        func show(_ code: String) { continuation.yield(.confirmCode(code)) }
        /// Fails the session without ending its stream, as a live one would
        /// before it finishes.
        func fail(_ failure: PairingFailure) { continuation.yield(.failed(failure)) }
        /// Saves the friend, as a ceremony past its commit point does.
        func save(_ peer: PairedPeer) {
            continuation.yield(.paired(peer))
            continuation.finish()
        }
        func holdCancel(at gate: Gate) { cancelGate = gate }
        func confirm(codesMatch: Bool) async { confirms.append(codesMatch) }
        func cancel() async {
            cancels += 1
            await cancelGate?.wait()
        }
    }

    /// Holds one pair call until released.
    actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var open = false
        private(set) var waiting = false

        func wait() async {
            if open { return }
            waiting = true
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            open = true
            waiter?.resume()
            waiter = nil
        }
    }

    @Test func aCancelledAttemptNeverShowsItsCodeOrTakesAConfirm() async {
        let friend = PeerID.random()
        let attacker = PeerID.random()
        let friendSession = ControlledSession()
        let attackerSession = ControlledSession()
        let gate = Gate()
        let directory = ScriptedDirectory(candidates: []) { peer, _ in
            if peer == friend {
                await gate.wait()
                return friendSession
            }
            return attackerSession
        }
        let model = PairingModel(directory: directory.directory)

        // The owner picks the friend; the pair call is still sending its hello.
        let picking = Task { await model.choose(PairingCandidate(peer: friend, deviceName: "Riley's iPhone")) }
        for _ in 0..<2000 where !(await gate.waiting) { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(model.phase == .connecting)

        // Cancel, then a nearby phone's request is joined.
        await model.cancel()
        #expect(model.phase == .choosing)
        directory.ask(from: attacker)
        await model.refresh()
        #expect(directory.starts.map(\.0) == [friend, attacker])

        // The attacker's code shows; then the cancelled call returns and its
        // session produces a code too.
        await attackerSession.show("111111")
        await eventually { model.phase == .comparing(code: "111111") }
        await gate.release()
        await picking.value
        await friendSession.show("222222")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await friendSession.cancels == 1, "the cancelled attempt's session is cancelled, not installed")
        #expect(model.phase == .comparing(code: "111111"), "the cancelled attempt's code never reaches the screen")

        await model.confirm(codesMatch: true)
        #expect(await attackerSession.confirms == [true], "the answer goes to the session whose code is shown")
        #expect(await friendSession.confirms.isEmpty)
    }

    /// The same for the sheet closing while a session is being created.
    @Test func anAttemptOverriddenByANewOneDropsItsEvents() async {
        let first = ControlledSession()
        let second = ControlledSession()
        let sessions = [first, second]
        let counter = Counter()
        let directory = ScriptedDirectory(candidates: []) { _, _ in sessions[await counter.next()] }
        let model = PairingModel(directory: directory.directory)
        let peer = PeerID.random()
        await model.choose(PairingCandidate(peer: peer))
        await first.show("111111")
        await eventually { model.phase == .comparing(code: "111111") }
        await model.cancel()
        await model.tryAgain()
        // The old session's late code is dropped; the new one's shows.
        await first.show("999999")
        await second.show("222222")
        await eventually { model.phase == .comparing(code: "222222") }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .comparing(code: "222222"))
        await model.confirm(codesMatch: true)
        #expect(await first.confirms.isEmpty)
        #expect(await second.confirms == [true])
        #expect(await first.cancels == 1)
    }

    /// Codex re-review of #104 (HIGH): a confirm queued from comparison A's
    /// buttons must not land on comparison B, which an automatic retry put
    /// on screen before the queued action ran.
    @Test func aConfirmFromAnOldComparisonConfirmsNothing() async throws {
        let first = ControlledSession()
        let second = ControlledSession()
        let sessions = [first, second]
        let counter = Counter()
        let directory = ScriptedDirectory(candidates: []) { _, _ in sessions[await counter.next()] }
        let clock = PairingClock()
        let model = PairingModel(directory: directory.directory, now: clock.now)
        let friend = PeerID.random()

        await model.choose(PairingCandidate(peer: friend))
        await first.show("111111")
        await eventually { model.phase == .comparing(code: "111111") }
        let rendered = try #require(model.comparison)
        #expect(rendered.code == "111111")

        // A fails, the other phone tries again, and B is on screen before
        // A's queued confirm runs.
        await first.fail(.timedOut)
        await eventually { model.phase == .failed(.timedOut) }
        clock.advance(PairingModel.rejoinDelay)
        directory.ask(from: friend)
        await model.refresh()
        await second.show("222222")
        await eventually { model.phase == .comparing(code: "222222") }

        await model.confirm(codesMatch: true, for: rendered)
        #expect(await first.confirms.isEmpty)
        #expect(await second.confirms.isEmpty, "B's code was never confirmed")
        #expect(model.phase == .comparing(code: "222222"))

        await model.confirm(codesMatch: true, for: try #require(model.comparison))
        #expect(await second.confirms == [true])
    }

    /// Codex re-review of #104: Try again awaits the old session's cancel.
    /// A Cancel and an automatic join during that wait must not let the
    /// suspended retry adopt the newer attempt and pair with the old phone.
    @Test func aRetryWaitingOnTheOldCancelYieldsToANewerAttempt() async throws {
        let old = ControlledSession()
        let joined = ControlledSession()
        let extra = ControlledSession()
        let sessions = [old, joined, extra]
        let counter = Counter()
        let directory = ScriptedDirectory(candidates: []) { _, _ in sessions[await counter.next()] }
        let model = PairingModel(directory: directory.directory)
        let friend = PeerID.random()
        let other = PeerID.random()

        await model.choose(PairingCandidate(peer: friend))
        await old.show("111111")
        await eventually { model.phase == .comparing(code: "111111") }
        await old.fail(.timedOut)
        await eventually { model.phase == .failed(.timedOut) }

        let gate = Gate()
        await old.holdCancel(at: gate)
        let retrying = Task { await model.tryAgain() }
        for _ in 0..<2000 where !(await gate.waiting) { try? await Task.sleep(for: .milliseconds(1)) }
        await model.tryAgain()
        #expect(await old.cancels == 1, "a second Try again while one runs does nothing")

        // Cancel, then another phone's request is joined, all while the
        // retry is still waiting on the old cancel.
        await model.cancel()
        #expect(model.phase == .choosing)
        directory.ask(from: other)
        await model.refresh()
        await joined.show("222222")
        await eventually { model.phase == .comparing(code: "222222") }

        await gate.release()
        await retrying.value
        try? await Task.sleep(for: .milliseconds(20))
        #expect(directory.starts.map(\.0) == [friend, other], "the stale retry never pairs again")
        #expect(model.phase == .comparing(code: "222222"))
        await model.confirm(codesMatch: true, for: try #require(model.comparison))
        #expect(await joined.confirms == [true])
        #expect(await extra.confirms.isEmpty)
    }

    /// Review round 3 of #104: each rejoin after a failure is another code
    /// a phone in the middle could try, so the sheet rejoins on its own once.
    /// After that the owner taps Try again.
    @Test func aSheetRejoinsOnItsOwnOnlyOnce() async {
        let directory = ScriptedDirectory(candidates: []) { _, _ in PairingModelTests.TimingOutSession() }
        let clock = PairingClock()
        let model = PairingModel(directory: directory.directory, now: clock.now)
        let friend = PeerID.random()
        await model.choose(PairingCandidate(peer: friend))
        await eventually { model.phase == .failed(.timedOut) }
        directory.ask(from: friend)

        clock.advance(PairingModel.rejoinDelay)
        await model.refresh()
        await eventually { model.phase == .failed(.timedOut) && directory.starts.count == 2 }
        #expect(directory.starts.count == 2, "the one automatic rejoin")
        clock.advance(PairingModel.rejoinDelay)
        await model.refresh()
        await model.refresh()
        #expect(directory.starts.count == 2, "no second one without a tap")

        await model.tryAgain()
        #expect(directory.starts.count == 3, "the owner's tap still works")
    }

    /// Review round 3 of #104 (low): past the point where both owners
    /// confirmed, the ceremony saves the friend even if Cancel is tapped
    /// (ADR 0101). The sheet keeps following that session and goes on to
    /// the name step instead of showing a failure over a saved friend.
    @Test func cancelWhileWaitingStillNamesAFriendTheCeremonySaved() async throws {
        let session = ControlledSession()
        let directory = ScriptedDirectory(candidates: []) { _, _ in session }
        let model = PairingModel(directory: directory.directory)
        let friend = Fixtures.peer("Phone")
        await model.choose(PairingCandidate(peer: friend.id, deviceName: "Riley's iPhone"))
        await session.show("111111")
        await eventually { model.phase == .comparing(code: "111111") }
        await model.confirm(codesMatch: true, for: try #require(model.comparison))
        #expect(model.phase == .waiting)

        await model.cancel()
        #expect(await session.cancels == 1)
        await session.save(try PairedPeer(publicKey: friend.publicKey, nickname: PairingModel.placeholderName, pairedAt: friend.pairedAt))
        await eventually { if case .naming = model.phase { true } else { false } }
        guard case .naming = model.phase else { Issue.record("expected the name step, got \(model.phase)"); return }
        #expect(model.name == "Riley")
        await model.saveName()
        #expect(directory.renames.map(\.1) == ["Riley"])
    }

    /// And when the ceremony had not saved yet, Cancel on Waiting ends it.
    @Test func cancelWhileWaitingEndsACeremonyThatHadNotSaved() async throws {
        let session = ControlledSession()
        let directory = ScriptedDirectory(candidates: []) { _, _ in session }
        let model = PairingModel(directory: directory.directory)
        await model.choose(PairingCandidate(peer: PeerID.random()))
        await session.show("111111")
        await eventually { model.phase == .comparing(code: "111111") }
        await model.confirm(codesMatch: true, for: try #require(model.comparison))
        await model.cancel()
        await session.fail(.cancelled)
        await eventually { model.phase == .failed(.cancelled) }
        #expect(model.phase == .failed(.cancelled))
    }

    actor Counter {
        private var value = 0
        func next() -> Int {
            defer { value += 1 }
            return value
        }
    }
}

extension PairingModel {
    /// For tests: confirm the comparison on screen now, in one main-actor
    /// turn, as a button rendered for it would.
    func confirm(codesMatch: Bool) async {
        guard let comparison else { return }
        await confirm(codesMatch: codesMatch, for: comparison)
    }
}

/// A clock the test moves, so timing rules run without waiting.
@MainActor
final class PairingClock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var now: @MainActor () -> Date { { [unowned self] in date } }
    func advance(_ seconds: TimeInterval) { date += seconds }
}
