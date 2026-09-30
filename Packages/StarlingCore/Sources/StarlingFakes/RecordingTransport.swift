import Foundation
import StarlingCore

/// A transport that records sends and lets a test inject inbound events.
/// Not a network simulation; use `LoopbackTransport` in StarlingTransport for that.
public actor RecordingTransport: Transport {
    public struct Sent: Hashable, Sendable {
        public let frame: Frame
        public let peer: PeerID
    }

    public nonisolated let kind: TransportKind
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    public private(set) var sent: [Sent] = []
    public private(set) var isStarted = false
    private var failure: TransportError?

    public init(localPeer: PeerID = .random(), kind: TransportKind = .loopback) {
        self.localPeer = localPeer
        self.kind = kind
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    public func start() async throws { isStarted = true }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        if let failure { throw failure }
        sent.append(Sent(frame: frame, peer: peer))
    }

    public func stop() async {
        isStarted = false
        continuation.finish()
    }

    /// Makes every later `send` throw.
    public func failSends(with error: TransportError?) { failure = error }

    public nonisolated func inject(_ event: TransportEvent) { continuation.yield(event) }
}
