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
    /// Bumped whenever a peer's sessions are torn down (disconnect, unpair,
    /// link loss, rollover). A pin lookup that started under an older
    /// generation is stale and must not create or install a session.
    private var generations: [PeerID: UInt64] = [:]
    /// Bumped only when a peer is revoked (`disconnect`, `unpair`). A pairing
    /// ceremony commits only if this is unchanged since it started.
    private var revocationGenerations: [PeerID: UInt64] = [:]
    private var revocationObservers: [@Sendable (PeerID) async -> Void] = []
    private var sendTail: Task<Void, Never>?
    /// Frames dropped since start, for tests and diagnostics. No reasons are kept.
    private(set) var droppedFrames = 0

    private struct Channel {
        let id: UInt64
        var session: NoiseSession
        /// Whether we sent KK message 1 for this session.
        let initiator: Bool
        /// Whether the other side is known to use this session. A responder's
        /// session is confirmed when it is promoted; an initiator's when any
        /// frame from the responder decrypts under it.
        var confirmed: Bool
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
        /// Receive only: the last confirmed session, kept while newer ones
        /// await confirmation, because the peer keeps using it until one
        /// reaches it. Survives any number of unconfirmed replacements.
        var lastConfirmed: Channel?
        /// Receive only: newer sessions replaced before they were confirmed
        /// (newest last), in case the peer switched to one of them.
        var superseded: [Channel] = []
        /// The timer resending our confirm until the responder acknowledges it.
        var confirmTimer: UInt64?
        /// Sessions abandoned for lack of an acknowledgement since the last
        /// confirmed one. Bounds re-handshakes on a link that loses them all.
        var unconfirmedRestarts = 0
        /// Responder sessions awaiting their first frame, newest last.
        var pending: [Channel] = []
        var initiation: Initiation?
        /// Initiator ephemeral keys already answered, to ignore replays of message 1.
        var answeredEphemerals: [Data] = []
        var droppedFrames = 0
    }

    static let maxPendingPerPeer = 4
    static let maxUnconfirmedRestarts = 2
    static let maxSupersededPerPeer = 2
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
        if let current = peers[peer]?.current, !current.confirmed,
           !spendRestart(peer, replacingUnconfirmed: true) { return }
        await initiate(with: peer)
    }

    /// Unpairs `peer`: the one call the app should use. Removes the pin, then
    /// revokes (see `disconnect(_:)`), so no session, pending handshake,
    /// pairing ceremony, or in-flight pairing save with the peer survives.
    public func unpair(_ peer: PeerID) async throws {
        do {
            try await pairedPeers.remove(peer)
        } catch {
            await disconnect(peer)
            throw error
        }
        await disconnect(peer)
    }

    /// Revokes `peer` without touching the store: ends its session, voids pin
    /// lookups in flight, and tells every `PairingService` on this transport
    /// to cancel its ceremony with the peer. Remove the pin first (or call
    /// `unpair(_:)`), or the next link-up will start a session again.
    public func disconnect(_ peer: PeerID) async {
        revocationGenerations[peer, default: 0] += 1
        tearDown(peer, announce: true)
        // Also when there was no state yet: a first handshake may be mid-lookup.
        generations[peer, default: 0] += 1
        for observer in revocationObservers { await observer(peer) }
    }

    /// How many times `peer` has been revoked. Pairing records it when a
    /// ceremony starts and saves only if it has not changed.
    public func revocationGeneration(of peer: PeerID) -> UInt64 {
        revocationGenerations[peer, default: 0]
    }

    /// Registers a handler run on every revocation. Used by `PairingService`.
    public func observeRevocations(_ handler: @escaping @Sendable (PeerID) async -> Void) {
        revocationObservers.append(handler)
    }

    /// What this layer knows about one link: the `PeerID` the link claims,
    /// and the static key the peer proved in the live session, if any. A
    /// proven key always hashes to the claimed ID; a link that claims a
    /// friend's ID without their key never gets one (ADR 0100).
    public func status(of peer: PeerID) -> SecureLinkStatus {
        let entry = peers[peer]
        return SecureLinkStatus(
            claimedPeer: peer,
            linkUp: entry?.linkUp ?? false,
            provenKey: entry?.current.flatMap { try? IdentityPublicKey(bytes: $0.session.remoteStatic.rawRepresentation) },
            handshakeInProgress: entry?.initiation != nil || entry?.pending.isEmpty == false || entry?.current?.confirmed == false,
            droppedFrames: entry?.droppedFrames ?? 0
        )
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
            guard let (type, body) = SecureWire.parse(frame) else { return drop(from: peer) }
            switch type {
            case .pairing:
                // Shorter than the frame it came in, so always a valid Frame.
                guard let inner = try? Frame(body) else { return drop(from: peer) }
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
              let pinned = await pinnedKey(for: peer)
        else { return drop(from: peer) }
        let ephemeral = Data(message.prefix(NoiseHandshakeState.dhLength))
        if peers[peer]?.answeredEphemerals.contains(ephemeral) == true { return drop(from: peer) }

        var handshake: NoiseHandshakeState
        let reply: Data
        do {
            handshake = try NoiseHandshakeState(
                pattern: .kk, initiator: false, prologue: SecureWire.kkPrologue,
                localStatic: identity.privateKey, remoteStatic: pinned
            )
            guard try handshake.readMessage(message).isEmpty else { return drop(from: peer) }
        } catch {
            return drop(from: peer)
        }

        // Both sides initiated at once: the lower PeerID's handshake wins.
        if peers[peer]?.initiation != nil {
            if localPeer < peer { return }
            peers[peer]?.initiation = nil
        }

        do {
            reply = try handshake.writeMessage(payload: Data())
            let session = try handshake.session()
            guard Self.proves(session, peer) else { return drop(from: peer) }
            var entry = peers[peer] ?? PeerState()
            nextHandshakeID += 1
            entry.pending.append(Channel(id: nextHandshakeID, session: session, initiator: false, confirmed: false))
            if entry.pending.count > Self.maxPendingPerPeer { entry.pending.removeFirst() }
            entry.answeredEphemerals.append(ephemeral)
            if entry.answeredEphemerals.count > Self.maxRememberedEphemerals { entry.answeredEphemerals.removeFirst() }
            peers[peer] = entry
        } catch {
            return drop(from: peer)
        }
        try? await serialized { transport in
            try await transport.inner.send(SecureWire.frame(.handshake2, reply), to: peer)
        }
    }

    private func receiveHandshake2(_ message: Data, from peer: PeerID) async {
        guard message.count == SecureWire.handshakeLength, var initiation = peers[peer]?.initiation else {
            return drop(from: peer)
        }
        let session: NoiseSession
        do {
            guard try initiation.handshake.readMessage(message).isEmpty else { return drop(from: peer) }
            session = try initiation.handshake.session()
        } catch {
            return drop(from: peer)
        }
        // KK authenticated the responder against the key pinned at initiation.
        guard Self.proves(session, peer) else { return drop(from: peer) }
        timers.removeValue(forKey: initiation.id)?.cancel()
        guard var entry = peers[peer] else { return }
        entry.initiation = nil
        entry.pending = []
        // The responder switches only when our confirm (or data) reaches it,
        // so keep accepting its frames under the old session until then.
        Self.retireCurrent(&entry)
        entry.current = Channel(id: initiation.id, session: session, initiator: true, confirmed: false)
        peers[peer] = entry
        armConfirmRetry(peer, channel: initiation.id, attemptsLeft: configuration.handshakeAttempts)
        await sendControl(.confirm, to: peer)
        announce(peer)
    }

    /// Resends our confirm until the responder acknowledges the new session.
    /// If it never does, the session may be unusable on its side: start over,
    /// a bounded number of times.
    private func armConfirmRetry(_ peer: PeerID, channel: UInt64, attemptsLeft: Int) {
        if let old = peers[peer]?.confirmTimer { timers.removeValue(forKey: old)?.cancel() }
        nextHandshakeID += 1
        let id = nextHandshakeID
        peers[peer]?.confirmTimer = id
        let timeout = configuration.handshakeTimeout
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.confirmTimedOut(peer, channel: channel, timer: id, attemptsLeft: attemptsLeft)
        }
    }

    private func confirmTimedOut(_ peer: PeerID, channel: UInt64, timer: UInt64, attemptsLeft: Int) async {
        timers[timer] = nil
        guard state == .started, let current = peers[peer]?.current, current.id == channel, !current.confirmed else { return }
        if attemptsLeft > 0 {
            armConfirmRetry(peer, channel: channel, attemptsLeft: attemptsLeft - 1)
            await sendControl(.confirm, to: peer)
            return
        }
        rollOver(peer)
        if spendRestart(peer, replacingUnconfirmed: true) { await initiate(with: peer) }
    }

    /// Sends a confirm or acknowledgement under the current session. Best
    /// effort: a lost one is covered by the confirm retry.
    private func sendControl(_ kind: SecureWire.PayloadKind, to peer: PeerID) async {
        try? await serialized { transport in
            let sealed = try transport.seal(kind, Data(), to: peer)
            try await transport.inner.send(sealed, to: peer)
        }
    }

    private func receiveTransport(_ body: Data, from peer: PeerID) {
        guard let (nonce, ciphertext) = SecureWire.parseTransport(body),
              nonce < configuration.maxMessagesPerSession,
              var entry = peers[peer]
        else { return drop(from: peer) }

        var plaintext: Data?
        var channelUsed: Channel?
        if var channel = entry.current, let opened = open(&channel, nonce: nonce, ciphertext: ciphertext) {
            if !channel.confirmed {
                // The responder sent under our new session, so it switched.
                channel.confirmed = true
                entry.lastConfirmed = nil
                entry.superseded = []
                entry.unconfirmedRestarts = 0
                if let timer = entry.confirmTimer { timers.removeValue(forKey: timer)?.cancel() }
                entry.confirmTimer = nil
            }
            entry.current = channel
            (plaintext, channelUsed) = (opened, channel)
        } else if var channel = entry.lastConfirmed, let opened = open(&channel, nonce: nonce, ciphertext: ciphertext) {
            entry.lastConfirmed = channel
            (plaintext, channelUsed) = (opened, channel)
        } else {
            for index in entry.superseded.indices.reversed() {
                var channel = entry.superseded[index]
                if let opened = open(&channel, nonce: nonce, ciphertext: ciphertext) {
                    entry.superseded[index] = channel
                    (plaintext, channelUsed) = (opened, channel)
                    break
                }
            }
        }
        if plaintext == nil {
            for index in entry.pending.indices.reversed() {
                var channel = entry.pending[index]
                if let opened = open(&channel, nonce: nonce, ciphertext: ciphertext) {
                    // The initiator used this session, so it is live: promote it.
                    channel.confirmed = true
                    entry.current = channel
                    entry.lastConfirmed = nil
                    entry.superseded = []
                    entry.pending = []
                    (plaintext, channelUsed) = (opened, channel)
                    break
                }
            }
        }
        guard let plaintext, let channelUsed, let first = plaintext.first,
              let kind = SecureWire.PayloadKind(rawValue: first)
        else { return drop(from: peer) }
        peers[peer] = entry
        announce(peer)
        switch kind {
        case .confirm:
            // Acknowledge every confirm on a session we answered, including a
            // retry whose earlier acknowledgement was lost.
            guard !channelUsed.initiator, channelUsed.id == entry.current?.id else { return }
            Task { await self.sendControl(.confirmAck, to: peer) }
        case .confirmAck:
            return
        case .data:
            let payload = Data(plaintext.dropFirst())
            guard payload.count <= ProtocolLimits.maxEnvelopeBytes, let frame = try? Frame(payload) else { return drop(from: peer) }
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
            // We may not send on it again, but the peer may still send on it
            // until our new session reaches it: rollOver keeps it for receiving.
            let unconfirmed = !channel.confirmed
            rollOver(peer)
            if spendRestart(peer, replacingUnconfirmed: unconfirmed) {
                Task { await self.initiate(with: peer) }
            }
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
        guard state == .started, peer != localPeer, let pinned = await pinnedKey(for: peer) else { return }
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

    /// Whether a new handshake may replace the current session. Replacing an
    /// unconfirmed one (confirm timeout, nonce cap, reconnect) spends from a
    /// budget of `maxUnconfirmedRestarts`, refilled only when a session is
    /// confirmed or the link comes back. So a link that loses every confirm
    /// or acknowledgement ends in silence, not in endless handshakes.
    private func spendRestart(_ peer: PeerID, replacingUnconfirmed: Bool) -> Bool {
        guard replacingUnconfirmed else { return true }
        let restarts = (peers[peer]?.unconfirmedRestarts ?? 0) + 1
        peers[peer]?.unconfirmedRestarts = restarts
        return restarts <= Self.maxUnconfirmedRestarts
    }

    /// Moves the current session aside for receiving only, before a newer
    /// one replaces it. A confirmed session becomes `lastConfirmed`; an
    /// unconfirmed one joins `superseded` and never displaces `lastConfirmed`.
    private static func retireCurrent(_ entry: inout PeerState) {
        guard let old = entry.current else { return }
        entry.current = nil
        if old.confirmed {
            entry.lastConfirmed = old
            entry.superseded = []
        } else {
            entry.superseded.append(old)
            if entry.superseded.count > maxSupersededPerPeer { entry.superseded.removeFirst() }
        }
    }

    /// Stops sending on the current session before a new handshake replaces
    /// it (nonce cap, unacknowledged confirm). Unlike `tearDown`, the
    /// receive-only sessions stay, so frames the peer sends meanwhile arrive.
    private func rollOver(_ peer: PeerID) {
        guard var entry = peers[peer] else { return }
        if let initiation = entry.initiation { timers.removeValue(forKey: initiation.id)?.cancel() }
        if let timer = entry.confirmTimer { timers.removeValue(forKey: timer)?.cancel() }
        entry.initiation = nil
        entry.confirmTimer = nil
        Self.retireCurrent(&entry)
        let wasAnnounced = entry.announced
        entry.announced = false
        peers[peer] = entry
        generations[peer, default: 0] += 1
        if wasAnnounced { continuation.yield(.peerUnavailable(peer)) }
    }

    private func tearDown(_ peer: PeerID, announce: Bool) {
        guard var state = peers[peer] else { return }
        generations[peer, default: 0] += 1
        if let initiation = state.initiation { timers.removeValue(forKey: initiation.id)?.cancel() }
        if let timer = state.confirmTimer { timers.removeValue(forKey: timer)?.cancel() }
        let wasAnnounced = state.announced
        state.confirmTimer = nil
        state.lastConfirmed = nil
        state.superseded = []
        state.current = nil
        state.pending = []
        state.initiation = nil
        state.announced = false
        peers[peer] = state
        if announce, wasAnnounced { continuation.yield(.peerUnavailable(peer)) }
    }

    /// The invariant behind every session this layer installs: the key the
    /// peer proved hashes to the ID its link claims. Only sessions that pass
    /// can become `current`, and only a completed handshake (initiator) or a
    /// frame that decrypts (responder) installs one, so a failed or
    /// unauthenticated handshake never displaces or shadows a live session.
    private static func proves(_ session: NoiseSession, _ peer: PeerID) -> Bool {
        (try? IdentityPublicKey(bytes: session.remoteStatic.rawRepresentation))?.peerID == peer
    }

    /// Looks up the key pinned for `peer`. Returns nil if the peer was torn
    /// down or disconnected while the lookup was suspended, so a pin read
    /// before an unpair can never start or answer a handshake after it.
    private func pinnedKey(for peer: PeerID) async -> X25519PublicKey? {
        let generation = generations[peer, default: 0]
        guard let paired = try? await pairedPeers.peer(for: peer), paired.id == peer,
              state == .started, generations[peer, default: 0] == generation
        else { return nil }
        return try? X25519PublicKey(rawRepresentation: paired.publicKey.bytes)
    }

    private func drop(from peer: PeerID) {
        droppedFrames += 1
        peers[peer]?.droppedFrames += 1
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

/// `SecureTransport.status(of:)`: the claimed link identity next to the proven one.
public struct SecureLinkStatus: Hashable, Sendable {
    /// The `PeerID` the wrapped transport reports for this link. A claim.
    public let claimedPeer: PeerID
    public let linkUp: Bool
    /// The static key proven in the live session, or nil if there is none.
    /// When present, `provenKey.peerID == claimedPeer`.
    public let provenKey: IdentityPublicKey?
    public let handshakeInProgress: Bool
    /// Frames from this claimed ID that were dropped (bad type, failed
    /// handshake, failed decryption, stale nonce). No reasons are kept.
    public let droppedFrames: Int
}

extension SecureTransport: PairingRevocations {}
