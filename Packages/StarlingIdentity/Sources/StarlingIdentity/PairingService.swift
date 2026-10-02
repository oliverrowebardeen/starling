import Foundation
import StarlingCore

public struct PairingConfiguration: Sendable {
    /// From starting a ceremony until the code is on screen.
    public var handshakeTimeout: Duration
    /// From the code appearing until both owners have answered.
    public var confirmationTimeout: Duration
    /// How often a ceremony that waits on the other phone sends its last
    /// message again (ADR 0260). Links lose frames; nothing else resends them.
    public var resendInterval: Duration
    /// How long a finished ceremony keeps answering the other phone's
    /// resends with its last messages, so a lost final `accept` or notice
    /// still arrives (ADR 0260).
    public var lingerDuration: Duration
    /// How long a request from another phone stays listed after its last hello.
    public var requestLifetime: Duration

    public init(
        handshakeTimeout: Duration = .seconds(60), confirmationTimeout: Duration = .seconds(120),
        resendInterval: Duration = .seconds(1), lingerDuration: Duration = .seconds(30),
        requestLifetime: Duration = .seconds(5)
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.confirmationTimeout = confirmationTimeout
        self.resendInterval = resendInterval
        self.lingerDuration = lingerDuration
        self.requestLifetime = requestLifetime
    }
}

public enum PairingServiceError: Error, Hashable, Sendable {
    case cannotPairWithSelf
    case notStarted
}

/// The pairing messages, for diagnostics.
public enum PairingMessage: String, Hashable, Sendable {
    case hello, message1 = "message 1", message2 = "message 2", message3 = "message 3"
    case reveal, accept, reject, cancel, abort
    /// An encrypted message that did not decrypt or did not fit.
    case secure
}

/// One step of a ceremony, for the Debug pairing log. Never carries keys,
/// nonces, or the code (ADR 0260).
public enum PairingStep: Hashable, Sendable {
    case started(initiator: Bool)
    case sent(PairingMessage)
    case resent(PairingMessage)
    /// No link took the frame. The ceremony keeps resending.
    case unsent(PairingMessage)
    case received(PairingMessage)
    /// A frame that did not fit the current step, dropped.
    case ignored(PairingMessage)
    /// The other phone started over before a code was shown; so did this one.
    case restarted
    case codeShown
    case confirmed(codesMatch: Bool)
    case peerAccepted
    case linkUp
    case linkDown
    /// Another phone asked to pair, with no ceremony running here.
    case requested
    /// A finished ceremony answered a resend with its last messages.
    case answeredAfterEnd
    case paired
    case failed(PairingFailure)
}

public struct PairingTrace: Hashable, Sendable {
    public let peer: PeerID
    public let step: PairingStep
}

/// In-person pairing (ADR 0003, ADR 0101, ADR 0260): Noise XX over
/// unauthenticated links, a 6-digit code both owners compare, and a
/// `PairedPeer` saved only after both owners confirm. A mismatch, cancel, or
/// timeout on either side leaves nothing stored on that side.
///
/// One owner picks the other phone and calls `pair(with:nickname:)`. The
/// other phone lists that as a request (`requests()`), and its owner, or the
/// app on their behalf, calls `pair(with:nickname:)` too. The service runs
/// over every link the phones share at once, sending each frame on all of
/// them, so both phones meet whichever link works. Peer IDs on every link
/// must be key-derived, as `SecureTransport.pairingLink` reports them. The
/// service is the single consumer of each link's events.
public actor PairingService {
    private struct Linger {
        let frames: [Frame]
        let peerAttempt: Data?
        let until: Date
        var lastReplay: Date?
        var replays = 0
    }

    private struct Request {
        let attempt: Data?
        var heard: Date
    }

    static let maxRequests = 16
    static let maxLingers = 16
    /// Replays per finished ceremony. Enough to cover a few lost answers,
    /// and bounded so two finished ceremonies whose replays reach each
    /// other cannot keep answering one another.
    static let maxReplays = 3

    private let identity: IdentityKeyPair
    private let pins: PinAuthority
    private let links: [any Transport]
    private let configuration: PairingConfiguration
    private let now: @Sendable () -> Date
    private let trace: (@Sendable (PairingTrace) -> Void)?
    private var ceremonies: [PeerID: PairingCeremony] = [:]
    private var lingers: [PeerID: Linger] = [:]
    private var pending: [PeerID: Request] = [:]
    private var loops: [Task<Void, Never>] = []
    private var started = false

    /// Pairs over `secureTransport.pairingLink` and commits pins through its
    /// authority, so unpairing is ordered against every commit.
    public init(
        secureTransport: SecureTransport,
        configuration: PairingConfiguration = PairingConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() },
        trace: (@Sendable (PairingTrace) -> Void)? = nil
    ) {
        self.init(authority: secureTransport.authority, links: [secureTransport.pairingLink], configuration: configuration, now: now, trace: trace)
    }

    /// Pairs over one link as `authority.identity`.
    public init(
        authority: PinAuthority,
        link: any Transport,
        configuration: PairingConfiguration = PairingConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() },
        trace: (@Sendable (PairingTrace) -> Void)? = nil
    ) {
        self.init(authority: authority, links: [link], configuration: configuration, now: now, trace: trace)
    }

    /// Pairs over several links at once as `authority.identity`, for example
    /// the `pairingLink` of every `SecureTransport` sharing `authority`. Pins
    /// are committed only through `authority`, the one every unpair also
    /// goes through.
    public init(
        authority: PinAuthority,
        links: [any Transport],
        configuration: PairingConfiguration = PairingConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() },
        trace: (@Sendable (PairingTrace) -> Void)? = nil
    ) {
        precondition(!links.isEmpty, "pairing needs at least one link")
        self.identity = authority.identity
        self.pins = authority
        self.links = links
        self.configuration = configuration
        self.now = now
        self.trace = trace
    }

    /// Starts the links (if needed) and begins listening for pairing
    /// traffic. Throws only if no link starts.
    public func start() async throws {
        guard !started else { return }
        started = true
        pins.observeRevocations { [weak self] peer, epoch in await self?.revocationNotice(peer, epoch: epoch) }
        for link in links {
            let events = link.events
            loops.append(Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.route(event)
                }
            })
        }
        var firstError: (any Error)?
        var anyStarted = false
        for link in links {
            do {
                try await link.start()
                anyStarted = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if !anyStarted, let firstError { throw firstError }
    }

    /// Stops listening and cancels every ceremony in progress.
    public func stop() async {
        for loop in loops { loop.cancel() }
        loops = []
        started = false
        for ceremony in ceremonies.values { await ceremony.cancel() }
        ceremonies = [:]
        lingers = [:]
        pending = [:]
    }

    /// Starts a ceremony with the phone the owner picked, or with a phone
    /// that asked (`requests()`). Replaces any ceremony already running with
    /// that peer.
    public func pair(with peer: PeerID, nickname: String) async throws -> any PairingSession {
        guard started else { throw PairingServiceError.notStarted }
        guard peer != identity.peerID else { throw PairingServiceError.cannotPairWithSelf }
        // Validates the nickname now, rather than after both owners confirm.
        _ = try PairedPeer(publicKey: identity.publicKey, nickname: nickname, pairedAt: Timestamp(now()))

        // Removed before the old one is cancelled, so its ending leaves no
        // linger that would answer the new ceremony's peer.
        if let previous = ceremonies.removeValue(forKey: peer) { await previous.cancel() }
        lingers[peer] = nil
        pending[peer] = nil
        let links = links
        let trace = trace
        let ceremony = PairingCeremony(
            peer: peer, nickname: nickname, identity: identity, pins: pins,
            send: { frame in await Self.send(frame, to: peer, over: links) },
            configuration: configuration, now: now,
            revocationEpoch: pins.epoch(of: peer),
            trace: { step in trace?(PairingTrace(peer: peer, step: step)) }
        )
        ceremonies[peer] = ceremony
        await ceremony.begin { [weak self] frames, peerAttempt in
            await self?.finished(ceremony, peer: peer, frames: frames, peerAttempt: peerAttempt)
        }
        return ceremony
    }

    /// Phones that asked to pair with this one in the last few seconds and
    /// have no ceremony running here, newest first. A request is a claim
    /// from an unauthenticated link: answering it only starts a ceremony,
    /// whose code comparison verifies the phone (ADR 0260).
    public func requests() -> [PeerID] {
        let cutoff = now().addingTimeInterval(-Self.seconds(configuration.requestLifetime))
        pending = pending.filter { $0.value.heard > cutoff }
        return pending.filter { ceremonies[$0.key] == nil }.sorted { $0.value.heard > $1.value.heard }.map(\.key)
    }

    /// A revocation notice from the authority, carrying the epoch the
    /// revocation produced. It can arrive late, after a new ceremony with the
    /// peer has started, so it ends only a ceremony that started under an
    /// older epoch. Unpairing wins: a ceremony with a revoked peer ends now.
    func revocationNotice(_ peer: PeerID, epoch: UInt64) async {
        await ceremonies[peer]?.revoke(startedBefore: epoch)
    }

    /// Sends on every link; true if at least one took the frame. Each link
    /// keeps its own order, so a phone reading any one link sees the
    /// ceremony's messages in the order they were sent.
    static func send(_ frame: Frame, to peer: PeerID, over links: [any Transport]) async -> Bool {
        var delivered = false
        for link in links where (try? await link.send(frame, to: peer)) != nil {
            delivered = true
        }
        return delivered
    }

    private func finished(_ ceremony: PairingCeremony, peer: PeerID, frames: [Frame], peerAttempt: Data?) {
        guard ceremonies[peer] === ceremony else { return }
        ceremonies[peer] = nil
        guard !frames.isEmpty else { return }
        lingers[peer] = Linger(frames: frames, peerAttempt: peerAttempt, until: now().addingTimeInterval(Self.seconds(configuration.lingerDuration)))
        if lingers.count > Self.maxLingers, let oldest = lingers.min(by: { $0.value.until < $1.value.until })?.key {
            lingers[oldest] = nil
        }
    }

    private func route(_ event: TransportEvent) async {
        switch event {
        case .received(let frame, let peer):
            if let ceremony = ceremonies[peer] {
                await ceremony.receive(frame.bytes)
            } else {
                await idle(frame.bytes, from: peer)
            }
        case .peerAvailable(let peer):
            if let ceremony = ceremonies[peer] {
                trace?(PairingTrace(peer: peer, step: .linkUp))
                await ceremony.linkAvailable()
            }
        case .peerUnavailable(let peer):
            if ceremonies[peer] != nil { trace?(PairingTrace(peer: peer, step: .linkDown)) }
        }
    }

    /// A frame from a phone with no ceremony running here. A hello for a new
    /// attempt is a request; anything else from a phone whose ceremony just
    /// ended gets that ceremony's last messages again.
    private func idle(_ bytes: Data, from peer: PeerID) async {
        guard peer != identity.peerID, let first = bytes.first, let type = PairingCeremony.MessageType(rawValue: first) else { return }
        let date = now()
        if let linger = lingers[peer], linger.until <= date { lingers[peer] = nil }
        if type == .hello {
            guard let attempt = PairingCeremony.attempt(in: Data(bytes.dropFirst())) else { return }
            if let linger = lingers[peer], let bound = linger.peerAttempt, attempt == bound {
                await replay(to: peer)
                return
            }
            let isNew = pending[peer]?.attempt != attempt
            pending[peer] = Request(attempt: attempt, heard: date)
            if pending.count > Self.maxRequests, let oldest = pending.min(by: { $0.value.heard < $1.value.heard })?.key {
                pending[oldest] = nil
            }
            if isNew { trace?(PairingTrace(peer: peer, step: .requested)) }
            return
        }
        await replay(to: peer)
    }

    /// Sends a finished ceremony's last messages again, at most once per
    /// half resend interval and `maxReplays` times, so a flood of frames
    /// cannot multiply them.
    private func replay(to peer: PeerID) async {
        guard var linger = lingers[peer], linger.replays < Self.maxReplays else { return }
        let date = now()
        if let last = linger.lastReplay, date.timeIntervalSince(last) < Self.seconds(configuration.resendInterval) / 2 { return }
        linger.lastReplay = date
        linger.replays += 1
        lingers[peer] = linger
        trace?(PairingTrace(peer: peer, step: .answeredAfterEnd))
        for frame in linger.frames { _ = await Self.send(frame, to: peer, over: links) }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// One ceremony with one peer. See `PairingService`, ADR 0101, and ADR 0260.
///
/// Messages (pairing frames, first byte is the type):
///
///     hello       both, until the handshake starts. Carries the sender's
///                 attempt ID: 8 random bytes, new for each `pair` call.
///     message 1   initiator: -> e
///     message 2   responder: <- e, ee, s, es   payload: commitment to responder nonce
///     message 3   initiator: -> s, se          payload: initiator nonce
///     secure      Noise transport messages: reveal (responder nonce), accept, reject, cancel
///     abort       unauthenticated cancel, only before keys exist. Carries
///                 the sender's attempt ID.
///
/// The peer with the lower `PeerID` is the XX initiator. While waiting on
/// the other phone, a ceremony sends its last message again every resend
/// interval, and answers a repeat of the message it last answered with the
/// same reply. Frames that do not parse, decrypt, or fit the current step
/// are dropped, so injected traffic cannot end a ceremony once keys exist;
/// only the code comparison decides. Before a code is shown, a hello for a
/// new attempt means the other phone started over, and so does this one,
/// with fresh keys and nonces.
actor PairingCeremony: PairingSession {
    enum MessageType: UInt8 {
        case hello = 0x01, message1 = 0x02, message2 = 0x03, message3 = 0x04, secure = 0x05, abort = 0x06
    }

    enum SecureKind: UInt8 {
        case reveal = 0x01, accept = 0x02, reject = 0x03, cancel = 0x04
    }

    /// `saving` begins once both owners have confirmed: that is the commit
    /// point, so a late cancel no longer changes the outcome.
    private enum Phase { case waiting, awaitingMessage2, awaitingMessage3, awaitingReveal, comparing, saving, finished }

    static let prologue = Data("Starling pairing v1".utf8)
    static let attemptLength = 8

    /// Parses the attempt field of a hello or abort body: `.some(id)` for 8
    /// bytes, `.some(nil)` for an empty body (a build from before ADR 0260,
    /// which names no attempt), and nil for any other length, which is dropped.
    static func attempt(in body: Data) -> Data?? {
        switch body.count {
        case 0: return .some(nil)
        case attemptLength: return .some(body)
        default: return nil
        }
    }

    nonisolated let events: AsyncStream<PairingEvent>
    private let continuation: AsyncStream<PairingEvent>.Continuation
    private let peer: PeerID
    private let nickname: String
    private let identity: IdentityKeyPair
    private let pins: PinAuthority
    private let send: @Sendable (Frame) async -> Bool
    private let configuration: PairingConfiguration
    private let now: @Sendable () -> Date
    private let trace: @Sendable (PairingStep) -> Void
    private let initiator: Bool
    /// The peer's epoch at the pin authority when the ceremony started.
    private let revocationEpoch: UInt64
    /// This ceremony's attempt ID. A restart keeps it, so two phones that
    /// restart for each other never loop.
    private let attempt: Data

    private var phase = Phase.waiting
    private var handshake: NoiseHandshakeState
    private var session: NoiseSession?
    /// Fresh for every handshake, restarts included: reusing a nonce after
    /// the other side saw it would let that side choose its own afterwards.
    private var localNonce = PairingCode.nonce()
    private var responderCommitment: Data?
    private var initiatorNonce: Data?
    private var localConfirmed = false
    private var remoteAccepted = false
    /// The latest attempt ID the peer's hellos carried.
    private var peerAttempt: Data?
    /// The last handshake message sent, resent while waiting on the peer.
    private var lastSent: (type: MessageType, frame: Frame)?
    /// The last handshake message answered, so a repeat gets the same reply.
    private var lastAnswered: Data?
    /// Every encrypted message sent, in order, resent together so the peer
    /// can decrypt them in sequence whichever copy it lost.
    private var secureSent: [Frame] = []
    private var timer: Task<Void, Never>?
    private var resender: Task<Void, Never>?
    private var onFinish: (@Sendable ([Frame], Data?) async -> Void)?

    init(
        peer: PeerID, nickname: String, identity: IdentityKeyPair, pins: PinAuthority,
        send: @escaping @Sendable (Frame) async -> Bool, configuration: PairingConfiguration,
        now: @escaping @Sendable () -> Date, revocationEpoch: UInt64,
        trace: @escaping @Sendable (PairingStep) -> Void = { _ in }
    ) {
        self.revocationEpoch = revocationEpoch
        self.peer = peer
        self.nickname = nickname
        self.identity = identity
        self.pins = pins
        self.send = send
        self.configuration = configuration
        self.now = now
        self.trace = trace
        initiator = identity.peerID < peer
        attempt = PairingCode.nonce().prefix(Self.attemptLength)
        (events, continuation) = AsyncStream.makeStream(of: PairingEvent.self)
        handshake = Self.freshHandshake(identity: identity, initiator: identity.peerID < peer)
    }

    private static func freshHandshake(identity: IdentityKeyPair, initiator: Bool) -> NoiseHandshakeState {
        // Force-try is safe: XX takes no remote key up front, which is the only failure.
        try! NoiseHandshakeState(
            pattern: .xx, initiator: initiator, prologue: prologue,
            localStatic: identity.privateKey, remoteStatic: nil
        )
    }

    func begin(onFinish: @escaping @Sendable ([Frame], Data?) async -> Void) async {
        self.onFinish = onFinish
        trace(.started(initiator: initiator))
        arm(configuration.handshakeTimeout)
        let interval = configuration.resendInterval
        resender = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.resend()
            }
        }
        await sendHello()
    }

    // MARK: PairingSession

    func confirm(codesMatch: Bool) async {
        guard phase == .comparing, !localConfirmed else { return }
        trace(.confirmed(codesMatch: codesMatch))
        guard codesMatch else { return await end(.codeMismatch, notice: .reject) }
        localConfirmed = true
        await sendSecure(.accept)
        await completeIfReady()
    }

    func cancel() async {
        await end(.cancelled, notice: .cancel)
    }

    /// The owner unpaired or disconnected this peer, producing `epoch`. Ends
    /// the ceremony only if it started under an older epoch; a ceremony that
    /// started after the revocation is left alone. One that is already
    /// saving is caught by the epoch check in `PinAuthority.commit`.
    func revoke(startedBefore epoch: UInt64) async {
        guard revocationEpoch < epoch else { return }
        await end(.cancelled, notice: .cancel)
    }

    // MARK: Link events

    /// A link to the peer came up: send what the peer is missing now rather
    /// than at the next resend.
    func linkAvailable() async {
        await resend()
    }

    func receive(_ bytes: Data) async {
        guard phase != .finished, let first = bytes.first, let type = MessageType(rawValue: first) else { return }
        let body = Data(bytes.dropFirst())
        switch type {
        case .hello:
            await receiveHello(body)
        case .message1 where !initiator && phase == .waiting:
            trace(.received(.message1))
            await answerMessage1(body)
        case .message2 where initiator && phase == .awaitingMessage2:
            trace(.received(.message2))
            await answerMessage2(body)
        case .message3 where !initiator && phase == .awaitingMessage3:
            trace(.received(.message3))
            await answerMessage3(body)
        case .message1, .message2, .message3:
            await receiveRepeat(type, body)
        case .secure:
            await receiveSecure(body)
        case .abort:
            receiveAbort(body)
        }
    }

    // MARK: Hellos and restarts

    private func receiveHello(_ body: Data) async {
        guard let parsed = Self.attempt(in: body) else { return trace(.ignored(.hello)) }
        if let theirs = parsed {
            if let bound = peerAttempt, bound != theirs {
                // The other phone started over. Before a code is shown, so
                // does this one; afterwards keys exist and a hello cannot
                // derail the comparison (ADR 0101 decision 4).
                guard showsNoCode else { return trace(.ignored(.hello)) }
                if phase != .waiting { restart() }
            }
            peerAttempt = theirs
        }
        guard phase == .waiting else { return }
        trace(.received(.hello))
        if initiator {
            await startHandshake()
        } else {
            await sendHello()
        }
    }

    private var showsNoCode: Bool {
        switch phase {
        case .waiting, .awaitingMessage2, .awaitingMessage3, .awaitingReveal: true
        case .comparing, .saving, .finished: false
        }
    }

    /// Back to the start of the handshake with fresh keys and nonces. The
    /// handshake timer keeps running, so restarts cannot extend a ceremony.
    private func restart() {
        trace(.restarted)
        phase = .waiting
        handshake = Self.freshHandshake(identity: identity, initiator: initiator)
        session = nil
        localNonce = PairingCode.nonce()
        responderCommitment = nil
        initiatorNonce = nil
        lastSent = nil
        lastAnswered = nil
        secureSent = []
    }

    /// An unauthenticated cancel ends a ceremony only before keys exist, and
    /// only if it names the attempt this ceremony is answering (or the peer
    /// has named none), so a stale abort cannot end a newer attempt.
    private func receiveAbort(_ body: Data) {
        guard let parsed = Self.attempt(in: body) else { return trace(.ignored(.abort)) }
        switch phase {
        case .waiting, .awaitingMessage2, .awaitingMessage3: break
        default: return trace(.ignored(.abort))
        }
        guard peerAttempt == nil || parsed == peerAttempt else { return trace(.ignored(.abort)) }
        trace(.received(.abort))
        fail(.cancelled)
    }

    /// A copy of the handshake message this ceremony last answered: the
    /// reply was lost, so send it again. Anything else is dropped.
    private func receiveRepeat(_ type: MessageType, _ body: Data) async {
        guard let lastAnswered, body == lastAnswered else { return trace(.ignored(Self.message(type))) }
        if let lastSent, showsNoCode {
            trace(.resent(Self.message(lastSent.type)))
            _ = await send(lastSent.frame)
        } else {
            // The repeated message 3: the reveal (and anything after it) was lost.
            await resendSecure()
        }
    }

    // MARK: Handshake

    private func startHandshake() async {
        guard let message = try? handshake.writeMessage(payload: Data()) else { return fail(.protocolError) }
        phase = .awaitingMessage2
        await sendHandshake(.message1, message)
    }

    private func answerMessage1(_ body: Data) async {
        var attempt = handshake
        guard let payload = try? attempt.readMessage(body), payload.isEmpty,
              let reply = try? attempt.writeMessage(payload: PairingCode.commitment(to: localNonce))
        else { return trace(.ignored(.message1)) }
        handshake = attempt
        lastAnswered = body
        phase = .awaitingMessage3
        await sendHandshake(.message2, reply)
    }

    private func answerMessage2(_ body: Data) async {
        var attempt = handshake
        guard let commitment = try? attempt.readMessage(body), commitment.count == 32,
              let reply = try? attempt.writeMessage(payload: localNonce),
              let session = try? attempt.session()
        else { return trace(.ignored(.message2)) }
        handshake = attempt
        guard acceptable(session) else { return await abandon() }
        self.session = session
        responderCommitment = commitment
        lastAnswered = body
        phase = .awaitingReveal
        await sendHandshake(.message3, reply)
    }

    private func answerMessage3(_ body: Data) async {
        var attempt = handshake
        guard let nonce = try? attempt.readMessage(body), nonce.count == PairingCode.nonceLength,
              let session = try? attempt.session()
        else { return trace(.ignored(.message3)) }
        handshake = attempt
        guard acceptable(session) else { return await abandon() }
        self.session = session
        initiatorNonce = nonce
        lastAnswered = body
        showCode(initiatorNonce: nonce, responderNonce: localNonce)
        await sendSecure(.reveal, localNonce)
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
        lastSent = nil
        arm(configuration.confirmationTimeout)
        trace(.codeShown)
        continuation.yield(.confirmCode(PairingCode.code(
            handshakeHash: session.handshakeHash, initiatorNonce: initiatorNonce, responderNonce: responderNonce
        )))
    }

    // MARK: After the handshake

    private func receiveSecure(_ body: Data) async {
        guard var session, let plaintext = try? session.receive.decrypt(ad: Data(), ciphertext: body),
              let first = plaintext.first, let kind = SecureKind(rawValue: first)
        else { return trace(.ignored(.secure)) }
        self.session = session
        let content = Data(plaintext.dropFirst())
        trace(.received(Self.message(kind)))
        switch (kind, phase) {
        case (.reveal, .awaitingReveal):
            // The responder must reveal the nonce it committed to before seeing ours.
            guard content.count == PairingCode.nonceLength, PairingCode.commitment(to: content) == responderCommitment else {
                return await abandon()
            }
            showCode(initiatorNonce: localNonce, responderNonce: content)
        case (.accept, .comparing):
            trace(.peerAccepted)
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
        resender?.cancel()
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

    // MARK: Resending

    /// Sends what the peer may be missing: the last handshake message while
    /// waiting on the next one, or every encrypted message once this owner
    /// has confirmed and waits on the other's answer.
    private func resend() async {
        switch phase {
        case .waiting:
            await sendHello(resend: true)
        case .awaitingMessage2, .awaitingMessage3, .awaitingReveal:
            guard let lastSent else { return }
            trace(.resent(Self.message(lastSent.type)))
            if !(await send(lastSent.frame)) { trace(.unsent(Self.message(lastSent.type))) }
        case .comparing where localConfirmed:
            await resendSecure()
        case .comparing, .saving, .finished:
            return
        }
    }

    private func resendSecure() async {
        guard !secureSent.isEmpty else { return }
        trace(.resent(.secure))
        for frame in secureSent { _ = await send(frame) }
    }

    // MARK: Plumbing

    private func abandon() async {
        await end(.protocolError, notice: .cancel)
    }

    /// Ends the ceremony on this phone, then tells the peer. The ending is
    /// final before anything is awaited: an accept that arrives while the
    /// notice is in flight finds the ceremony finished and cannot pin the
    /// peer. The notice is sealed first, while the session keys still exist,
    /// and is kept with the other final messages for the linger.
    private func end(_ failure: PairingFailure, notice: SecureKind) async {
        guard phase != .finished, phase != .saving else { return }
        if let frame = sealedNotice(notice) {
            if session == nil {
                secureSent = [frame]
            } else {
                secureSent.append(frame)
            }
            fail(failure)
            trace(.sent(session == nil ? .abort : Self.message(notice)))
            _ = await send(frame)
        } else {
            fail(failure)
        }
    }

    private func sealedNotice(_ kind: SecureKind) -> Frame? {
        guard var session else { return try? Frame(Data([MessageType.abort.rawValue]) + attempt) }
        guard let ciphertext = try? session.send.encrypt(ad: Data(), plaintext: Data([kind.rawValue])) else { return nil }
        self.session = session
        return try? Frame(Data([MessageType.secure.rawValue]) + ciphertext)
    }

    private func sendSecure(_ kind: SecureKind, _ content: Data = Data()) async {
        guard var session else { return }
        guard let ciphertext = try? session.send.encrypt(ad: Data(), plaintext: Data([kind.rawValue]) + content),
              let frame = try? Frame(Data([MessageType.secure.rawValue]) + ciphertext)
        else { return fail(.protocolError) }
        self.session = session
        secureSent.append(frame)
        trace(.sent(Self.message(kind)))
        if !(await send(frame)) { trace(.unsent(Self.message(kind))) }
    }

    private func sendHello(resend: Bool = false) async {
        guard let frame = try? Frame(Data([MessageType.hello.rawValue]) + attempt) else { return }
        trace(resend ? .resent(.hello) : .sent(.hello))
        if !(await send(frame)) { trace(.unsent(.hello)) }
    }

    private func sendHandshake(_ type: MessageType, _ body: Data) async {
        guard let frame = try? Frame(Data([type.rawValue]) + body) else { return fail(.protocolError) }
        lastSent = (type, frame)
        trace(.sent(Self.message(type)))
        if !(await send(frame)) { trace(.unsent(Self.message(type))) }
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
        resender?.cancel()
        resender = nil
        session = nil
        if case .failed(let failure) = event { trace(.failed(failure)) } else { trace(.paired) }
        continuation.yield(event)
        continuation.finish()
        let frames = secureSent
        let peerAttempt = peerAttempt
        if let onFinish { Task { await onFinish(frames, peerAttempt) } }
    }

    private static func message(_ type: MessageType) -> PairingMessage {
        switch type {
        case .hello: .hello
        case .message1: .message1
        case .message2: .message2
        case .message3: .message3
        case .secure: .secure
        case .abort: .abort
        }
    }

    private static func message(_ kind: SecureKind) -> PairingMessage {
        switch kind {
        case .reveal: .reveal
        case .accept: .accept
        case .reject: .reject
        case .cancel: .cancel
        }
    }
}

extension PairingStep: CustomStringConvertible {
    /// One line for the Debug pairing log.
    public var description: String {
        switch self {
        case .started(let initiator): "started as \(initiator ? "initiator" : "responder")"
        case .sent(let message): "sent \(message.rawValue)"
        case .resent(let message): "sent \(message.rawValue) again"
        case .unsent(let message): "no link took \(message.rawValue)"
        case .received(let message): "received \(message.rawValue)"
        case .ignored(let message): "ignored \(message.rawValue)"
        case .restarted: "the other phone started over; restarted the handshake"
        case .codeShown: "code shown"
        case .confirmed(let codesMatch): codesMatch ? "owner says the codes match" : "owner says the codes differ"
        case .peerAccepted: "the other owner confirmed"
        case .linkUp: "link up"
        case .linkDown: "link down"
        case .requested: "asked to pair by this phone"
        case .answeredAfterEnd: "answered a resend after the ceremony ended"
        case .paired: "paired"
        case .failed(let failure): "failed: \(failure)"
        }
    }
}

extension PairingTrace: CustomStringConvertible {
    public var description: String { "\(peer.short): \(step)" }
}
