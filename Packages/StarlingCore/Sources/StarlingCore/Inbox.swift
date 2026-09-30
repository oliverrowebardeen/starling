import Foundation

/// Why `Inbox` dropped an inbound frame.
public enum InboxDrop: Error, Hashable, Sendable {
    case codec(CodecError)
    case wrongRecipient
    /// The envelope's sender differs from the peer the link reported.
    case senderMismatch
    case replay
    case stale
    case fromFuture
}

public enum InboxEvent: Hashable, Sendable {
    case peerAvailable(PeerID)
    case peerUnavailable(PeerID)
    case message(Envelope)
    case dropped(from: PeerID, reason: InboxDrop)
}

/// The only sanctioned way to receive a message.
///
/// Decodes and validates frames, checks addressing, and rejects replays with a
/// sliding window per `(sender, conversation)`. Features consume `InboxEvent`s,
/// never raw transport events.
///
/// Phase 0 limits (see `docs/THREAT_MODEL.md` once written): replay state is
/// in memory and bounded, so a replay older than `maxAge` or from before an
/// app restart is caught only by the age check. Phase 1's secure channel adds
/// per-session nonces.
public actor Inbox {
    public static let replayWindow: UInt64 = 64
    public static let maxTrackedConversations = 1_024

    private struct ReplayKey: Hashable { let sender: PeerID; let conversation: ConversationID }
    private struct ReplayState { var highest: UInt64; var seen: Set<UInt64>; var lastUsed: Date }

    public nonisolated let localPeer: PeerID
    private let codec: EnvelopeCodec
    private let now: @Sendable () -> Date
    private let maxAge: TimeInterval
    private let maxClockSkew: TimeInterval
    private var replay: [ReplayKey: ReplayState] = [:]

    /// - Parameters:
    ///   - maxAge: Oldest `sentAt` accepted. Local links want minutes; the
    ///     Phase 2 relay will need hours.
    ///   - maxClockSkew: How far in the future `sentAt` may be.
    public init(
        localPeer: PeerID,
        codec: EnvelopeCodec = EnvelopeCodec(),
        maxAge: Duration = .seconds(600),
        maxClockSkew: Duration = .seconds(120),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.localPeer = localPeer
        self.codec = codec
        self.maxAge = Self.seconds(maxAge)
        self.maxClockSkew = Self.seconds(maxClockSkew)
        self.now = now
    }

    /// Validates one frame. Pure apart from replay bookkeeping.
    public func accept(_ frame: Frame, from claimedSender: PeerID) -> Result<Envelope, InboxDrop> {
        let envelope: Envelope
        do {
            envelope = try codec.decode(frame.bytes)
        } catch let error as CodecError {
            return .failure(.codec(error))
        } catch {
            return .failure(.codec(.malformed(String(describing: error))))
        }

        guard envelope.recipient == localPeer else { return .failure(.wrongRecipient) }
        guard envelope.sender == claimedSender else { return .failure(.senderMismatch) }

        let current = now()
        let sentAt = envelope.sentAt.date
        guard sentAt >= current.addingTimeInterval(-maxAge) else { return .failure(.stale) }
        guard sentAt <= current.addingTimeInterval(maxClockSkew) else { return .failure(.fromFuture) }

        guard recordSequence(envelope, at: current) else { return .failure(.replay) }
        return .success(envelope)
    }

    /// Maps one transport event to an inbox event.
    public func process(_ event: TransportEvent) -> InboxEvent {
        switch event {
        case .peerAvailable(let peer): return .peerAvailable(peer)
        case .peerUnavailable(let peer): return .peerUnavailable(peer)
        case .received(let frame, let peer):
            switch accept(frame, from: peer) {
            case .success(let envelope): return .message(envelope)
            case .failure(let reason): return .dropped(from: peer, reason: reason)
            }
        }
    }

    /// Consumes `transport.events` (its single consumer) and yields inbox
    /// events until the transport stops or the stream is cancelled.
    public nonisolated func events(from transport: any Transport) -> AsyncStream<InboxEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in transport.events {
                    continuation.yield(await self.process(event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordSequence(_ envelope: Envelope, at time: Date) -> Bool {
        let key = ReplayKey(sender: envelope.sender, conversation: envelope.conversation)
        let sequence = envelope.sequence
        guard var state = replay[key] else {
            evictIfNeeded()
            replay[key] = ReplayState(highest: sequence, seen: [sequence], lastUsed: time)
            return true
        }
        // Written as subtractions of a smaller value from a larger one, so
        // no peer-chosen sequence (including UInt64.max) can overflow.
        if sequence < state.highest, state.highest - sequence >= Self.replayWindow { return false }
        if state.seen.contains(sequence) { return false }
        state.seen.insert(sequence)
        if sequence > state.highest {
            state.highest = sequence
            // Every element of `seen` is now at most `sequence`.
            state.seen = state.seen.filter { sequence - $0 < Self.replayWindow }
        }
        state.lastUsed = time
        replay[key] = state
        return true
    }

    private func evictIfNeeded() {
        guard replay.count >= Self.maxTrackedConversations,
              let oldest = replay.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
        else { return }
        replay.removeValue(forKey: oldest)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
