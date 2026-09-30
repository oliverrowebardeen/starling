import Foundation
import StarlingCore

public struct SecureTransportConfiguration: Sendable {
    /// Messages one side may send in a session before it is torn down and a
    /// new handshake runs. Far below Noise's 2^64-1 nonce limit, so a nonce
    /// can never repeat or wrap (ADR 0003 care requirement 3).
    public var maxMessagesPerSession: UInt64
    /// How long an initiator waits for handshake message 2 before retrying.
    public var handshakeTimeout: Duration
    /// Handshake attempts per trigger (link up, `reconnect`, session rollover).
    public var handshakeAttempts: Int

    public init(maxMessagesPerSession: UInt64 = 1 << 20, handshakeTimeout: Duration = .seconds(5), handshakeAttempts: Int = 3) {
        precondition(maxMessagesPerSession > 1 && maxMessagesPerSession < .max, "session cap must leave the reserved nonce unused")
        self.maxMessagesPerSession = maxMessagesPerSession
        self.handshakeTimeout = handshakeTimeout
        self.handshakeAttempts = max(1, handshakeAttempts)
    }
}

/// The secure channel from ADR 0003: a `Transport` decorator that
/// authenticates paired peers with Noise KK and encrypts every frame.
///
/// - The wrapped transport's `localPeer` must be this identity's key-derived
///   `PeerID`, and it must report remote peers by theirs (ADR 0003 decision 4).
///   A link's peer ID is only a claim; this layer checks it against the key
///   pinned for that ID.
/// - `peerAvailable` is emitted only once a session with the pinned key is
///   live, and `received` only for frames that decrypt under it. Everything
///   else (unknown keys, tampered, truncated, replayed, reordered, or forged
///   frames) is dropped without a reply, so the wire never says why.
/// - Plaintext frames are capped at `ProtocolLimits.maxEnvelopeBytes`, so
///   ciphertext frames stay within `ProtocolLimits.maxFrameBytes`.
/// - Pairing traffic for unpaired devices shares the link through
///   `pairingLink`, which is unauthenticated at this layer.
public actor SecureTransport: Transport {
    public nonisolated let kind: TransportKind
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    /// A plain `Transport` view of the same link for `PairingService`.
    public nonisolated var pairingLink: any Transport { PairingLink(owner: self) }
    nonisolated let pairingEvents: AsyncStream<TransportEvent>

    private let inner: any Transport
    private let identity: IdentityKeyPair
    private let pairedPeers: any PairedPeerStore
    private let configuration: SecureTransportConfiguration
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let pairingContinuation: AsyncStream<TransportEvent>.Continuation

    private enum State { case idle, started, stopped }
    private var state = State.idle
    private var peers: [PeerID: PeerState] = [:]
    private var eventLoop: Task<Void, Never>?
    private var timers: [UInt64: Task<Void, Never>] = [:]
    private var nextHandshakeID: UInt64 = 0
    private var sendTail: Task<Void, Never>?
    /// Frames dropped since start, for tests and diagnostics. No reasons are kept.
    private(set) var droppedFrames = 0

    private struct Channel {
        var session: NoiseSession
        /// The lowest nonce still acceptable: nonces must strictly increase.
        var nextReceiveNonce: UInt64 = 0
    }

    private struct Initiation {
        let id: UInt64
        var handshake: NoiseHandshakeState
        var attemptsLeft: Int
    }

    private struct PeerState {
        var linkUp = false
        var announced = false
        var current: Channel?
        /// Responder sessions awaiting their first frame, newest last.
        var pending: [Channel] = []
        var initiation: Initiation?
        /// Initiator ephemeral keys already answered, to ignore replays of message 1.
        var answeredEphemerals: [Data] = []
    }

    static let maxPendingPerPeer = 4
    static let maxRememberedEphemerals = 64

    public init(
        wrapping inner: any Transport,
        identity: IdentityKeyPair,
        pairedPeers: any PairedPeerStore,
        configuration: SecureTransportConfiguration = SecureTransportConfiguration()
    ) {
        self.inner = inner
        self.identity = identity
        self.pairedPeers = pairedPeers
        self.configuration = configuration
        kind = inner.kind
        localPeer = identity.peerID
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        // Pairing traffic is unauthenticated; a bounded buffer keeps a flood
        // from an unpaired device from growing memory while nobody pairs.
        (pairingEvents, pairingContinuation) = AsyncStream.makeStream(
            of: TransportEvent.self, bufferingPolicy: .bufferingNewest(64)
        )
    }

    // MARK: Transport

    public func start() async throws {
        switch state {
        case .started: return
        case .stopped: throw TransportError.stopped
        case .idle: break
        }
        guard inner.localPeer == localPeer else {
            throw TransportError.failed("wrapped transport must use this identity's PeerID")
        }
        state = .started
        let events = inner.events
        eventLoop = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.innerFinished()
        }
        do {
            try await inner.start()
        } catch {
            await stop()
            throw error
        }
    }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        guard state == .started else { throw state == .idle ? TransportError.notStarted : TransportError.stopped }
        guard frame.bytes.count <= ProtocolLimits.maxEnvelopeBytes else {
            throw TransportError.failed("frame exceeds \(ProtocolLimits.maxEnvelopeBytes) bytes")
        }
        try await serialized { transport in
            let sealed = try transport.seal(.data, frame.bytes, to: peer)
            try await transport.inner.send(sealed, to: peer)
        }
    }

    public func stop() async {
        guard state != .stopped else { return }
        state = .stopped
        eventLoop?.cancel()
        eventLoop = nil
        for timer in timers.values { timer.cancel() }
        timers = [:]
        peers = [:]
        await inner.stop()
        continuation.finish()
        pairingContinuation.finish()
    }

    // MARK: Session control

    /// Starts a fresh handshake with a pinned peer, for example right after
    /// pairing. The current session, if any, keeps working until it succeeds.
    public func reconnect(_ peer: PeerID) async {
        guard state == .started else { return }
        await initiate(with: peer)
    }

    /// Ends the session with `peer` without starting a new one, for example
    /// after unpairing. Remove the peer from the store first, or the next
    /// link-up will pair the session again.
    public func disconnect(_ peer: PeerID) {
        tearDown(peer, announce: true)
    }

    // MARK: Inbound

    private func handle(_ event: TransportEvent) async {
        guard state == .started else { return }
        switch event {
        case .peerAvailable(let peer):
            pairingContinuation.yield(event)
            guard peer != localPeer else { return }
            peers[peer, default: PeerState()].linkUp = true
            if peers[peer]?.current == nil, peers[peer]?.initiation == nil {
                await initiate(with: peer)
            }
        case .peerUnavailable(let peer):
            pairingContinuation.yield(event)
            tearDown(peer, announce: true)
            // Keep the replay cache across link flaps; forget everything else.
            peers[peer] = PeerState(answeredEphemerals: peers[peer]?.answeredEphemerals ?? [])
        case .received(let frame, let peer):
            guard let (type, body) = SecureWire.parse(frame) else { return drop() }
            switch type {
            case .pairing:
                // Shorter than the frame it came in, so always a valid Frame.
                guard let inner = try? Frame(body) else { return drop() }
                pairingContinuation.yield(.received(inner, from: peer))
            case .handshake1: await receiveHandshake1(body, from: peer)
            case .handshake2: await receiveHandshake2(body, from: peer)
            case .transport: receiveTransport(body, from: peer)
            }
        }
    }

    private func innerFinished() {
        guard state == .started else { return }
        Task { await self.stop() }
    }

    private func receiveHandshake1(_ message: Data, from peer: PeerID) async {
        guard message.count == SecureWire.handshakeLength, peer != localPeer,
              let pinned = await pinnedKey(for: peer), state == .started
        else { return drop() }
        let ephemeral = Data(message.prefix(NoiseHandshakeState.dhLength))
        if peers[peer]?.answeredEphemerals.contains(ephemeral) == true { return drop() }

        var handshake: NoiseHandshakeState
        let reply: Data
        do {
            handshake = try NoiseHandshakeState(
                pattern: .kk, initiator: false, prologue: SecureWire.kkPrologue,
                localStatic: identity.privateKey, remoteStatic: pinned
            )
            guard try handshake.readMessage(message).isEmpty else { return drop() }
        } catch {
            return drop()
        }

        // Both sides initiated at once: the lower PeerID's handshake wins.
        if peers[peer]?.initiation != nil {
            if localPeer < peer { return }
            peers[peer]?.initiation = nil
        }

        do {
            reply = try handshake.writeMessage(payload: Data())
            let session = try handshake.session()
            var entry = peers[peer] ?? PeerState()
            entry.pending.append(Channel(session: session))
            if entry.pending.count > Self.maxPendingPerPeer { entry.pending.removeFirst() }
            entry.answeredEphemerals.append(ephemeral)
            if entry.answeredEphemerals.count > Self.maxRememberedEphemerals { entry.answeredEphemerals.removeFirst() }
            peers[peer] = entry
        } catch {
            return drop()
        }
        try? await serialized { transport in
            try await transport.inner.send(SecureWire.frame(.handshake2, reply), to: peer)
        }
    }

    private func receiveHandshake2(_ message: Data, from peer: PeerID) async {
        guard message.count == SecureWire.handshakeLength, var initiation = peers[peer]?.initiation else {
            return drop()
        }
        let session: NoiseSession
        do {
            guard try initiation.handshake.readMessage(message).isEmpty else { return drop() }
            session = try initiation.handshake.session()
        } catch {
            return drop()
        }
        // KK authenticated the responder against the key pinned at initiation.
        timers.removeValue(forKey: initiation.id)?.cancel()
        peers[peer]?.initiation = nil
        peers[peer]?.pending = []
        peers[peer]?.current = Channel(session: session)
        try? await serialized { transport in
            let sealed = try transport.seal(.confirm, Data(), to: peer)
            try await transport.inner.send(sealed, to: peer)
        }
        announce(peer)
    }

    private func receiveTransport(_ body: Data, from peer: PeerID) {
        guard let (nonce, ciphertext) = SecureWire.parseTransport(body),
              nonce < configuration.maxMessagesPerSession,
              var state = peers[peer]
        else { return drop() }

        var plaintext: Data?
        if var channel = state.current, let opened = open(&channel, nonce: nonce, ciphertext: ciphertext) {
            state.current = channel
            plaintext = opened
        } else {
            for index in state.pending.indices.reversed() {
                var channel = state.pending[index]
                if let opened = open(&channel, nonce: nonce, ciphertext: ciphertext) {
                    // The initiator used this session, so it is live: promote it.
                    state.current = channel
                    state.pending = []
                    plaintext = opened
                    break
                }
            }
        }
        guard let plaintext, let first = plaintext.first, let kind = SecureWire.PayloadKind(rawValue: first) else {
            return drop()
        }
        peers[peer] = state
        announce(peer)
        switch kind {
        case .confirm:
            return
        case .data:
            let payload = Data(plaintext.dropFirst())
            guard payload.count <= ProtocolLimits.maxEnvelopeBytes, let frame = try? Frame(payload) else { return drop() }
            continuation.yield(.received(frame, from: peer))
        }
    }

    /// Decrypts under an explicit nonce, which must exceed every nonce already
    /// accepted on this channel. Leaves the channel unchanged on failure.
    private func open(_ channel: inout Channel, nonce: UInt64, ciphertext: Data) -> Data? {
        guard nonce >= channel.nextReceiveNonce else { return nil }
        var receive = channel.session.receive
        receive.setNonce(nonce)
        guard let plaintext = try? receive.decrypt(ad: Data(), ciphertext: ciphertext) else { return nil }
        channel.session.receive = receive
        channel.nextReceiveNonce = nonce + 1
        return plaintext
    }

    // MARK: Outbound

    /// Encrypts one payload for `peer` under the current session. Rolls the
    /// session over instead of ever reaching the nonce cap.
    private func seal(_ kind: SecureWire.PayloadKind, _ payload: Data, to peer: PeerID) throws -> Frame {
        guard var channel = peers[peer]?.current else { throw TransportError.peerUnreachable(peer) }
        let nonce = channel.session.send.nonce
        guard nonce < configuration.maxMessagesPerSession else {
            tearDown(peer, announce: true)
            Task { await self.initiate(with: peer) }
            throw TransportError.peerUnreachable(peer)
        }
        var plaintext = Data(capacity: payload.count + 1)
        plaintext.append(kind.rawValue)
        plaintext.append(payload)
        let ciphertext = try channel.session.send.encrypt(ad: Data(), plaintext: plaintext)
        peers[peer]?.current = channel
        return try SecureWire.transportFrame(nonce: nonce, ciphertext: ciphertext)
    }

    fileprivate func sendPairing(_ frame: Frame, to peer: PeerID) async throws {
        guard state == .started else { throw state == .idle ? TransportError.notStarted : TransportError.stopped }
        let wrapped = try SecureWire.frame(.pairing, frame.bytes)
        try await serialized { transport in try await transport.inner.send(wrapped, to: peer) }
    }

    fileprivate func startForPairing() async throws {
        try await start()
    }

    private func initiate(with peer: PeerID, attempts: Int? = nil) async {
        guard state == .started, peer != localPeer, let pinned = await pinnedKey(for: peer), state == .started else { return }
        var handshake: NoiseHandshakeState
        let message: Data
        do {
            handshake = try NoiseHandshakeState(
                pattern: .kk, initiator: true, prologue: SecureWire.kkPrologue,
                localStatic: identity.privateKey, remoteStatic: pinned
            )
            message = try handshake.writeMessage(payload: Data())
        } catch {
            return
        }
        if let previous = peers[peer]?.initiation { timers.removeValue(forKey: previous.id)?.cancel() }
        nextHandshakeID += 1
        let id = nextHandshakeID
        let attemptsLeft = (attempts ?? configuration.handshakeAttempts) - 1
        peers[peer, default: PeerState()].initiation = Initiation(id: id, handshake: handshake, attemptsLeft: attemptsLeft)
        let timeout = configuration.handshakeTimeout
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.handshakeTimedOut(peer, id: id)
        }
        try? await serialized { transport in
            try await transport.inner.send(SecureWire.frame(.handshake1, message), to: peer)
        }
    }

    private func handshakeTimedOut(_ peer: PeerID, id: UInt64) async {
        timers[id] = nil
        guard let initiation = peers[peer]?.initiation, initiation.id == id else { return }
        peers[peer]?.initiation = nil
        guard initiation.attemptsLeft > 0 else { return }
        await initiate(with: peer, attempts: initiation.attemptsLeft)
    }

    // MARK: Helpers

    private func announce(_ peer: PeerID) {
        guard peers[peer]?.current != nil, peers[peer]?.announced == false else { return }
        peers[peer]?.announced = true
        continuation.yield(.peerAvailable(peer))
    }

    private func tearDown(_ peer: PeerID, announce: Bool) {
        guard var state = peers[peer] else { return }
        if let initiation = state.initiation { timers.removeValue(forKey: initiation.id)?.cancel() }
        let wasAnnounced = state.announced
        state.current = nil
        state.pending = []
        state.initiation = nil
        state.announced = false
        peers[peer] = state
        if announce, wasAnnounced { continuation.yield(.peerUnavailable(peer)) }
    }

    private func pinnedKey(for peer: PeerID) async -> X25519PublicKey? {
        guard let paired = try? await pairedPeers.peer(for: peer), paired.id == peer else { return nil }
        return try? X25519PublicKey(rawRepresentation: paired.publicKey.bytes)
    }

    private func drop() {
        droppedFrames += 1
    }

    /// Runs link sends one at a time, in call order, so explicit nonces reach
    /// the peer in increasing order even when callers send concurrently.
    private func serialized(_ operation: @escaping @Sendable (isolated SecureTransport) async throws -> Void) async throws {
        let previous = sendTail
        let task = Task {
            await previous?.value
            try await operation(self)
        }
        sendTail = Task { _ = await task.result }
        try await task.value
    }
}

/// `SecureTransport.pairingLink`: pairing frames only, unauthenticated.
struct PairingLink: Transport {
    let owner: SecureTransport

    var kind: TransportKind { owner.kind }
    var localPeer: PeerID { owner.localPeer }
    var events: AsyncStream<TransportEvent> { owner.pairingEvents }

    func start() async throws {
        try await owner.startForPairing()
    }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        try await owner.sendPairing(frame, to: peer)
    }

    /// The secure transport owns the link; stopping pairing leaves it running.
    func stop() async {}
}
