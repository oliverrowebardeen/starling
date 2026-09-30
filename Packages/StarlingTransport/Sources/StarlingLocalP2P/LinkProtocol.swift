import Foundation
import StarlingCore

/// TLV message types on a LocalP2P link.
enum LinkMessageType: Int {
    /// First message in each direction: see `LinkHello`.
    case hello = 1
    /// One Starling frame.
    case frame = 2
}

/// The link-level hello. Identifies the peer on this connection so duplicate
/// connections can be resolved (TN3213 "Create a peer identifier"), and names
/// the sender's Bonjour service so the dialing rule can tell which discovered
/// service a connection belongs to. The service name is already public.
///
/// Layout: "STRL", version byte, 32-byte PeerID, name length byte, UTF-8 name.
/// Unauthenticated in Phase 0, like everything else on this link.
package struct LinkHello: Hashable, Sendable {
    package static let magic = Data("STRL".utf8)
    package static let version: UInt8 = 0
    package static let maxServiceNameBytes = 63

    package let peer: PeerID
    package let serviceName: String

    package init(peer: PeerID, serviceName: String) throws {
        guard (1...Self.maxServiceNameBytes).contains(serviceName.utf8.count) else {
            throw ValidationError("LinkHello", "service name must be 1-\(Self.maxServiceNameBytes) bytes")
        }
        self.peer = peer
        self.serviceName = serviceName
    }

    package init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        let headerCount = Self.magic.count + 1 + PeerID.byteCount + 1
        guard bytes.count > headerCount else { throw ValidationError("LinkHello", "too short") }
        guard Data(bytes[0..<4]) == Self.magic else { throw ValidationError("LinkHello", "bad magic") }
        guard bytes[4] == Self.version else { throw ValidationError("LinkHello", "unsupported version \(bytes[4])") }
        let nameCount = Int(bytes[headerCount - 1])
        guard bytes.count == headerCount + nameCount, let name = String(bytes: bytes[headerCount...], encoding: .utf8) else {
            throw ValidationError("LinkHello", "bad service name")
        }
        try self.init(peer: PeerID(bytes: Data(bytes[5..<(5 + PeerID.byteCount)])), serviceName: name)
    }

    package var encoded: Data {
        Self.magic + Data([Self.version]) + peer.bytes + Data([UInt8(serviceName.utf8.count)]) + Data(serviceName.utf8)
    }
}

/// Decides which side opens the connection, so two devices normally end up
/// with exactly one link and no duplicate to arbitrate. Compares the random
/// per-launch service names, which both sides know from Bonjour.
package enum DialRule {
    /// How long the non-dialing side waits before dialing anyway, in case
    /// discovery was one-sided.
    package static let fallbackDelay: Duration = .seconds(3)

    package static func shouldDialImmediately(ownServiceName: String, discovered: String) -> Bool {
        ownServiceName > discovered
    }
}

/// Backoff for redialing an advertised peer whose link dropped or whose dial
/// failed. The browser only reports discovery changes, so without retries a
/// pair can stay disconnected while both services remain advertised.
package enum RetryPolicy {
    package static let maxAttempts = 5

    /// 1, 2, 4, 8, then 16 seconds; nil once attempts are exhausted.
    package static func delay(forAttempt attempt: Int) -> Duration? {
        guard (1...maxAttempts).contains(attempt) else { return nil }
        return .seconds(1 << (attempt - 1))
    }
}

/// Which services a browser update should start dialing.
package enum Discovery {
    /// Services absent from the previous update. A browser update lists every
    /// advertised service, so dialing all of them would redial peers whose
    /// retries are exhausted each time an unrelated phone appears. A service
    /// that disappears and returns counts as new, which resets its budget.
    package static func newlyDiscovered(previous: Set<String>, current: Set<String>) -> [String] {
        current.subtracting(previous).sorted()
    }
}

package enum LinkDirection: Hashable, Sendable {
    case outgoing, incoming
}

/// Chooses which connection survives when two exist between the same pair,
/// which only happens after a `DialRule` fallback races the normal dial.
///
/// ADR 0004: the peer with the greater `PeerID` keeps its outgoing
/// connection. Both sides apply the same rule, so they agree without talking.
/// Frames in flight on the dropped connection are lost, which the
/// `Transport` contract allows.
package enum LinkArbiter {
    /// The direction, from the local side's point of view, that should survive.
    package static func preferredDirection(local: PeerID, remote: PeerID) -> LinkDirection {
        local > remote ? .outgoing : .incoming
    }

    /// Whether a newly identified link should replace the existing one.
    package static func shouldReplace(existing: LinkDirection, with new: LinkDirection, local: PeerID, remote: PeerID) -> Bool {
        existing != new && new == preferredDirection(local: local, remote: remote)
    }
}

/// A random, per-launch Bonjour service name. Never the device name and never
/// a persistent ID, so nearby devices cannot track us (TN3213 "Design for
/// privacy").
package enum ServiceName {
    package static func random() -> String {
        "starling-" + (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}
