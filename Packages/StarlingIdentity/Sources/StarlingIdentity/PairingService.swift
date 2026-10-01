import Foundation
import StarlingCore

public struct PairingConfiguration: Sendable {
    /// From starting a ceremony until the code is on screen.
    public var handshakeTimeout: Duration
    /// From the code appearing until both owners have answered.
    public var confirmationTimeout: Duration

    public init(handshakeTimeout: Duration = .seconds(30), confirmationTimeout: Duration = .seconds(120)) {
        self.handshakeTimeout = handshakeTimeout
        self.confirmationTimeout = confirmationTimeout
    }
}

public enum PairingServiceError: Error, Hashable, Sendable {
    case cannotPairWithSelf
    case notStarted
}

/// In-person pairing (ADR 0003, ADR 0101): Noise XX over an unauthenticated
/// link, a 6-digit code both owners compare, and a `PairedPeer` saved only
/// after both owners confirm. A mismatch, cancel, timeout, or link loss on
/// either side leaves nothing stored on that side.
///
/// Both owners pick each other and call `pair(with:nickname:)`. The link can
/// be any `Transport` whose peer IDs are key-derived, typically
/// `SecureTransport.pairingLink` so pairing and the secure channel share one
/// link. The service is the single consumer of the link's events.
public actor PairingService {
    private let identity: IdentityKeyPair
    private let pins: PinAuthority
    private let link: any Transport
    private let configuration: PairingConfiguration
    private let now: @Sendable () -> Date
    private var ceremonies: [PeerID: PairingCeremony] = [:]
    private var loop: Task<Void, Never>?

    /// Pairs over `secureTransport.pairingLink` and commits pins through its
    /// authority, so unpairing is ordered against every commit.
    public init(
        secureTransport: SecureTransport,
        configuration: PairingConfiguration = PairingConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(authority: secureTransport.authority, link: secureTransport.pairingLink, configuration: configuration, now: now)
    }

    /// Pairs over any link as `authority.identity`. Pins are committed only
    /// through `authority`, the one every unpair also goes through.
    public init(
        authority: PinAuthority,
        link: any Transport,
        configuration: PairingConfiguration = PairingConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = authority.identity
        self.pins = authority
        self.link = link
        self.configuration = configuration
        self.now = now
    }

    /// Starts the link (if needed) and begins listening for pairing traffic.
    public func start() async throws {
        guard loop == nil else { return }
        pins.observeRevocations { [weak self] peer in await self?.revoked(peer) }
        let events = link.events
        loop = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.route(event)
            }
        }
        try await link.start()
    }

    /// Stops listening and cancels every ceremony in progress.
    public func stop() async {
        loop?.cancel()
        loop = nil
        for ceremony in ceremonies.values { await ceremony.cancel() }
        ceremonies = [:]
    }

    /// Starts a ceremony with the device the owner picked. The other owner
    /// must do the same on their phone. Replaces any ceremony already running
    /// with that peer.
    public func pair(with peer: PeerID, nickname: String) async throws -> any PairingSession {
        guard loop != nil else { throw PairingServiceError.notStarted }
        guard peer != identity.peerID else { throw PairingServiceError.cannotPairWithSelf }
        // Validates the nickname now, rather than after both owners confirm.
        _ = try PairedPeer(publicKey: identity.publicKey, nickname: nickname, pairedAt: Timestamp(now()))

        if let previous = ceremonies.removeValue(forKey: peer) { await previous.cancel() }
        let ceremony = PairingCeremony(
            peer: peer, nickname: nickname, identity: identity, pins: pins,
            link: link, configuration: configuration, now: now,
            revocationEpoch: pins.epoch(of: peer)
        )
        ceremonies[peer] = ceremony
        await ceremony.begin { [weak self] in await self?.finished(ceremony, peer: peer) }
        return ceremony
    }

    /// Unpairing wins: a ceremony with a revoked peer ends now.
    private func revoked(_ peer: PeerID) async {
        await ceremonies[peer]?.revoke()
    }

    private func finished(_ ceremony: PairingCeremony, peer: PeerID) {
        if ceremonies[peer] === ceremony { ceremonies[peer] = nil }
    }

    private func route(_ event: TransportEvent) async {
        switch event {
        case .received(let frame, let peer): await ceremonies[peer]?.receive(frame.bytes)
        case .peerAvailable(let peer): await ceremonies[peer]?.linkAvailable()
        case .peerUnavailable(let peer): await ceremonies[peer]?.linkLost()
        }
    }
}

/// One ceremony with one peer. See `PairingService` and ADR 0101.
///
/// Messages (pairing frames, first byte is the type):
///
///     hello       both, until the handshake starts (lets either side start first)
///     message 1   initiator: -> e
///     message 2   responder: <- e, ee, s, es   payload: commitment to responder nonce
///     message 3   initiator: -> s, se          payload: initiator nonce
///     secure      Noise transport messages: reveal (responder nonce), accept, reject, cancel
///     abort       unauthenticated cancel, only before keys exist
///
/// The peer with the lower `PeerID` is the XX initiator. Frames that do not
/// parse, decrypt, or fit the current step are dropped, so injected traffic
/// cannot end a ceremony once keys exist; only the code comparison decides.
actor PairingCeremony: PairingSession {
    enum MessageType: UInt8 {
        case hello = 0x01, message1 = 0x02, message2 = 0x03, message3 = 0x04, secure = 0x05, abort = 0x06
    }

    enum SecureKind: UInt8 {
        case reveal = 0x01, accept = 0x02, reject = 0x03, cancel = 0x04
    }

    /// `saving` begins once both owners have confirmed: that is the commit
    /// point, so a late cancel or link loss no longer changes the outcome.
    private enum Phase { case waiting, awaitingMessage2, awaitingMessage3, awaitingReveal, comparing, saving, finished }

    static let prologue = Data("Starling pairing v1".utf8)

    nonisolated let events: AsyncStream<PairingEvent>
    private let continuation: AsyncStream<PairingEvent>.Continuation
    private let peer: PeerID
    private let nickname: String
    private let identity: IdentityKeyPair
    private let pins: PinAuthority
    private let link: any Transport
    private let configuration: PairingConfiguration
    private let now: @Sendable () -> Date
    private let initiator: Bool
    /// The peer's epoch at the pin authority when the ceremony started.
    private let revocationEpoch: UInt64

    private var phase = Phase.waiting
    private var handshake: NoiseHandshakeState
    private var session: NoiseSession?
    private let localNonce = PairingCode.nonce()
    private var responderCommitment: Data?
    private var initiatorNonce: Data?
    private var localConfirmed = false
    private var remoteAccepted = false
    private var timer: Task<Void, Never>?
    private var onFinish: (@Sendable () async -> Void)?

    init(
        peer: PeerID, nickname: String, identity: IdentityKeyPair, pins: PinAuthority,
        link: any Transport, configuration: PairingConfiguration, now: @escaping @Sendable () -> Date,
        revocationEpoch: UInt64
    ) {
        self.revocationEpoch = revocationEpoch
        self.peer = peer
        self.nickname = nickname
        self.identity = identity
        self.pins = pins
        self.link = link
        self.configuration = configuration
        self.now = now
        initiator = identity.peerID < peer
        (events, continuation) = AsyncStream.makeStream(of: PairingEvent.self)
        // Force-try is safe: XX takes no remote key up front, which is the only failure.
        handshake = try! NoiseHandshakeState(
            pattern: .xx, initiator: identity.peerID < peer, prologue: Self.prologue,
            localStatic: identity.privateKey, remoteStatic: nil
        )
    }

    func begin(onFinish: @escaping @Sendable () async -> Void) async {
        self.onFinish = onFinish
        arm(configuration.handshakeTimeout)
        await send(.hello, Data())
    }

    // MARK: PairingSession

    func confirm(codesMatch: Bool) async {
        guard phase == .comparing, !localConfirmed else { return }
        guard codesMatch else { return await end(.codeMismatch, notice: .reject) }
        localConfirmed = true
        await sendSecure(.accept)
        await completeIfReady()
    }

    func cancel() async {
        await end(.cancelled, notice: .cancel)
    }

    /// The owner unpaired this peer while the ceremony ran. A ceremony that
    /// is already saving is caught by the epoch check in `PinAuthority.commit`.
    func revoke() async {
        await end(.cancelled, notice: .cancel)
    }

    // MARK: Link events

    func linkAvailable() async {
        if phase == .waiting { await send(.hello, Data()) }
    }

    func linkLost() {
        guard phase != .finished, phase != .saving else { return }
        fail(.transportFailed)
    }

    func receive(_ bytes: Data) async {
        guard phase != .finished, let first = bytes.first, let type = MessageType(rawValue: first) else { return }
        let body = Data(bytes.dropFirst())
        switch (type, phase, initiator) {
        case (.hello, .waiting, true):
            await startHandshake()
        case (.hello, .waiting, false):
            await send(.hello, Data())
        case (.message1, .waiting, false):
            await answerMessage1(body)
        case (.message2, .awaitingMessage2, true):
            await answerMessage2(body)
        case (.message3, .awaitingMessage3, false):
            await answerMessage3(body)
        case (.secure, _, _):
            await receiveSecure(body)
        case (.abort, .waiting, _), (.abort, .awaitingMessage2, _), (.abort, .awaitingMessage3, _):
            fail(.cancelled)
        default:
            return
        }
    }

    // MARK: Handshake

    private func startHandshake() async {
        guard let message = try? handshake.writeMessage(payload: Data()) else { return fail(.protocolError) }
        phase = .awaitingMessage2
        await send(.message1, message)
    }

    private func answerMessage1(_ body: Data) async {
        var attempt = handshake
        guard let payload = try? attempt.readMessage(body), payload.isEmpty,
              let reply = try? attempt.writeMessage(payload: PairingCode.commitment(to: localNonce))
        else { return }
        handshake = attempt
        phase = .awaitingMessage3
        await send(.message2, reply)
    }

    private func answerMessage2(_ body: Data) async {
        var attempt = handshake
        guard let commitment = try? attempt.readMessage(body), commitment.count == 32,
              let reply = try? attempt.writeMessage(payload: localNonce),
              let session = try? attempt.session()
        else { return }
        handshake = attempt
        guard acceptable(session) else { return await abandon() }
        self.session = session
        responderCommitment = commitment
        phase = .awaitingReveal
        await send(.message3, reply)
    }

    private func answerMessage3(_ body: Data) async {
        var attempt = handshake
        guard let nonce = try? attempt.readMessage(body), nonce.count == PairingCode.nonceLength,
              let session = try? attempt.session()
        else { return }
        handshake = attempt
        guard acceptable(session) else { return await abandon() }
        self.session = session
        initiatorNonce = nonce
        await sendSecure(.reveal, localNonce)
        showCode(initiatorNonce: nonce, responderNonce: localNonce)
    }

    /// The remote key must be the one the link claimed (so the secure channel
    /// can find it later by that ID) and must not be our own.
    private func acceptable(_ session: NoiseSession) -> Bool {
        guard let key = try? IdentityPublicKey(bytes: session.remoteStatic.rawRepresentation) else { return false }
        return key.peerID == peer && key != identity.publicKey
    }

    private func showCode(initiatorNonce: Data, responderNonce: Data) {
        guard let session else { return }
        phase = .comparing
        arm(configuration.confirmationTimeout)
        continuation.yield(.confirmCode(PairingCode.code(
            handshakeHash: session.handshakeHash, initiatorNonce: initiatorNonce, responderNonce: responderNonce
        )))
    }

    // MARK: After the handshake

    private func receiveSecure(_ body: Data) async {
        guard var session, let plaintext = try? session.receive.decrypt(ad: Data(), ciphertext: body),
              let first = plaintext.first, let kind = SecureKind(rawValue: first)
        else { return }
        self.session = session
        let content = Data(plaintext.dropFirst())
        switch (kind, phase) {
        case (.reveal, .awaitingReveal):
            // The responder must reveal the nonce it committed to before seeing ours.
            guard content.count == PairingCode.nonceLength, PairingCode.commitment(to: content) == responderCommitment else {
                return await abandon()
            }
            showCode(initiatorNonce: localNonce, responderNonce: content)
        case (.accept, .comparing):
            remoteAccepted = true
            await completeIfReady()
        case (.reject, .comparing):
            fail(.codeMismatch)
        case (.cancel, _):
            fail(.cancelled)
        default:
            return
        }
    }

    private func completeIfReady() async {
        guard phase == .comparing, localConfirmed, remoteAccepted, let session else { return }
        phase = .saving
        timer?.cancel()
        do {
            let key = try IdentityPublicKey(bytes: session.remoteStatic.rawRepresentation)
            let paired = try PairedPeer(publicKey: key, nickname: nickname, pairedAt: Timestamp(now()))
            // Unpairing wins: the authority commits only if the peer's epoch
            // has not moved since the ceremony started, and rolls back (no
            // pin, epoch moved again) if it moves before the commit ends.
            let committed = try await pins.commit(paired, ifEpochIs: revocationEpoch)
            finish(committed ? .paired(paired) : .failed(.cancelled))
        } catch {
            finish(.failed(.protocolError))
        }
    }

    // MARK: Plumbing


    private func abandon() async {
        await end(.protocolError, notice: .cancel)
    }

    /// Ends the ceremony on this phone, then tells the peer. The ending is
    /// final before anything is awaited: an accept that arrives while the
    /// notice is in flight finds the ceremony finished and cannot pin the
    /// peer. The notice is sealed first, while the session keys still exist.
    private func end(_ failure: PairingFailure, notice: SecureKind) async {
        guard phase != .finished, phase != .saving else { return }
        let frame = sealedNotice(notice)
        fail(failure)
        if let frame { try? await link.send(frame, to: peer) }
    }

    private func sealedNotice(_ kind: SecureKind) -> Frame? {
        guard var session else { return try? Frame(Data([MessageType.abort.rawValue])) }
        guard let ciphertext = try? session.send.encrypt(ad: Data(), plaintext: Data([kind.rawValue])) else { return nil }
        self.session = session
        return try? Frame(Data([MessageType.secure.rawValue]) + ciphertext)
    }

    private func sendSecure(_ kind: SecureKind, _ content: Data = Data()) async {
        guard var session else { return }
        guard let ciphertext = try? session.send.encrypt(ad: Data(), plaintext: Data([kind.rawValue]) + content) else {
            return fail(.protocolError)
        }
        self.session = session
        await send(.secure, ciphertext)
    }

    private func send(_ type: MessageType, _ body: Data) async {
        do {
            try await link.send(Frame(Data([type.rawValue]) + body), to: peer)
        } catch {
            fail(.transportFailed)
        }
    }

    private func arm(_ timeout: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut()
        }
    }

    private func timedOut() async {
        await end(.timedOut, notice: .cancel)
    }

    private func fail(_ failure: PairingFailure) {
        guard phase != .saving else { return }
        finish(.failed(failure))
    }

    private func finish(_ event: PairingEvent) {
        guard phase != .finished else { return }
        phase = .finished
        timer?.cancel()
        timer = nil
        session = nil
        continuation.yield(event)
        continuation.finish()
        if let onFinish { Task { await onFinish() } }
    }
}
