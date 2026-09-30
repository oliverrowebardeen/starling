import Foundation

public enum TransportKind: String, Hashable, Sendable, Codable {
    case loopback, localP2P, wifiAware, relay
}

/// Opaque bytes moved by a transport. Bounded by `ProtocolLimits.maxFrameBytes`.
public struct Frame: Hashable, Sendable {
    public let bytes: Data

    public init(_ bytes: Data) throws {
        guard bytes.count <= ProtocolLimits.maxFrameBytes else {
            throw ValidationError("Frame", "\(bytes.count) bytes exceeds \(ProtocolLimits.maxFrameBytes)")
        }
        self.bytes = bytes
    }
}

public enum TransportEvent: Hashable, Sendable {
    /// The peer can be sent frames now.
    case peerAvailable(PeerID)
    case peerUnavailable(PeerID)
    /// A frame arrived. `from` is the peer ID the link claims; it is not
    /// authenticated unless this transport is wrapped by a secure channel.
    case received(Frame, from: PeerID)
}

public enum TransportError: Error, Hashable, Sendable {
    case notStarted
    case stopped
    case peerUnreachable(PeerID)
    case failed(String)
}

/// Moves frames between peers. Knows nothing about envelopes, policy, or keys.
///
/// Rules for implementations:
/// - `events` has a single consumer (normally `Inbox`). It finishes after `stop()`.
/// - `send` delivers the frame intact or throws. Ordering per peer is preserved.
/// - Transports do not authenticate (ADR 0003). The Phase 1 secure channel is a
///   decorator that itself conforms to `Transport`, so nothing above changes.
/// - Transports never inspect frame contents.
public protocol Transport: Sendable {
    var kind: TransportKind { get }
    var localPeer: PeerID { get }
    var events: AsyncStream<TransportEvent> { get }

    func start() async throws
    func send(_ frame: Frame, to peer: PeerID) async throws
    func stop() async
}
