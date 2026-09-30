import Foundation
import StarlingCore
import StarlingLocalP2P

/// A paired device as the local system names it (`WAPairedDevice.ID`). The
/// value is local to this phone: the friend's phone uses a different ID for
/// us, so it never goes on the wire.
package typealias AwareDeviceID = UInt64

/// Whether a link may carry frames yet.
package enum LinkState: Hashable, Sendable {
    /// Identified by its hello but not the direction `LinkArbiter` prefers.
    /// Held without sending, in case the preferred link is still on its way,
    /// so no frame is ever sent on a link that arbitration then drops.
    case provisional
    /// Carries frames.
    case active
}

package struct LinkRecord: Hashable, Sendable {
    package let id: UUID
    package let peer: PeerID
    package let direction: LinkDirection
    /// The paired device on the other end, when the radio can tell.
    package let device: AwareDeviceID?
    package fileprivate(set) var state: LinkState
}

/// What to do with a link whose hello just arrived.
package struct Admission: Hashable, Sendable {
    /// The new link's state, or nil if it loses to an existing link and must close.
    package var state: LinkState?
    /// Announce `peerAvailable` for the new link's peer.
    package var announce = false
    /// Links replaced by this one. Close them.
    package var closed: [UUID] = []
    /// Other peers that lost their only active link. Announce `peerUnavailable`.
    package var unavailable: [PeerID] = []
}

/// Bookkeeping for Wi-Fi Aware links, kept free of I/O so it runs in unit
/// tests on macOS (ADR 0110).
///
/// Both phones publish and subscribe the same service, so both can dial. The
/// table keeps at most one link per peer and per paired device, and decides
/// who dials first:
///
/// - Wi-Fi Aware discovery carries no per-launch name to compare (LocalP2P's
///   `DialRule` input), but a hello teaches us which `PeerID` sits behind a
///   paired device. Once known, the side with the greater `PeerID` dials at
///   once and the other waits `DialRule.fallbackDelay`. That is `DialRule`
///   applied to the two IDs' hex strings, and it agrees with `LinkArbiter`,
///   which keeps the greater side's outgoing link.
/// - Before any hello, both sides dial. The link `LinkArbiter` does not
///   prefer stays provisional until the grace period passes or the peer sends
///   on it, so a dial race never loses a frame.
package struct LinkTable: Sendable {
    package let localPeer: PeerID
    package private(set) var links: [PeerID: LinkRecord] = [:]
    /// Learned from hellos. A claim, like every `PeerID` a transport reports.
    package private(set) var peersByDevice: [AwareDeviceID: PeerID] = [:]

    package init(localPeer: PeerID) {
        self.localPeer = localPeer
    }

    // MARK: Role resolution

    /// Whether to dial `device` as soon as it is discovered, or only after
    /// `DialRule.fallbackDelay` if the other side has not dialed us by then.
    package func dialsImmediately(_ device: AwareDeviceID) -> Bool {
        guard let remote = peersByDevice[device] else { return true }
        return DialRule.shouldDialImmediately(ownServiceName: localPeer.hex, discovered: remote.hex)
    }

    /// Whether any link, provisional or active, already reaches `device`.
    package func isLinked(_ device: AwareDeviceID) -> Bool {
        if links.values.contains(where: { $0.device == device }) { return true }
        guard let peer = peersByDevice[device] else { return false }
        return links[peer] != nil
    }

    /// The device a peer was last seen on, for redialing after a link drops.
    package func device(for peer: PeerID) -> AwareDeviceID? {
        if let device = links[peer]?.device { return device }
        return peersByDevice.first { $0.value == peer }?.key
    }

    // MARK: Links

    package func activeLink(to peer: PeerID) -> LinkRecord? {
        guard let link = links[peer], link.state == .active else { return nil }
        return link
    }

    /// The link with this ID, if it is still the current one for its peer.
    package func current(_ id: UUID) -> LinkRecord? {
        links.values.first { $0.id == id }
    }

    /// Records a link whose hello named `peer`, replacing or losing to any
    /// existing link for the same peer or device.
    package mutating func admit(id: UUID, peer: PeerID, direction: LinkDirection, device: AwareDeviceID?) -> Admission {
        var admission = Admission()
        guard peer != localPeer else { return admission }

        let preferred = LinkArbiter.preferredDirection(local: localPeer, remote: peer)
        var announce = true
        if let existing = links[peer] {
            // A second link in the same direction means the peer redialed, so
            // the old link is likely dead (for example after an app restart)
            // and the newer one wins. A link in the other direction wins only
            // if it is the preferred one.
            guard existing.direction == direction || direction == preferred else { return admission }
            announce = existing.state != .active
            admission.closed.append(existing.id)
        }

        // One link per paired device: a device now claiming a different peer
        // takes over from whatever link it had before.
        if let device {
            for other in links.values where other.device == device && other.peer != peer {
                links[other.peer] = nil
                admission.closed.append(other.id)
                if other.state == .active { admission.unavailable.append(other.peer) }
            }
            peersByDevice[device] = peer
        }

        let state: LinkState = direction == preferred || links[peer]?.state == .active ? .active : .provisional
        links[peer] = LinkRecord(id: id, peer: peer, direction: direction, device: device, state: state)
        admission.state = state
        admission.announce = state == .active && announce
        return admission
    }

    /// Promotes a provisional link: its grace period passed, or the peer sent
    /// on it (so the peer already treats it as active). Returns true if the
    /// peer just became available.
    package mutating func activate(_ id: UUID) -> Bool {
        guard var link = current(id), link.state == .provisional else { return false }
        link.state = .active
        links[link.peer] = link
        return true
    }

    /// Forgets a link that closed. Returns it if it was still current.
    package mutating func remove(_ id: UUID) -> LinkRecord? {
        guard let link = current(id) else { return nil }
        links[link.peer] = nil
        return link
    }

    package mutating func removeAll() -> [LinkRecord] {
        defer { links.removeAll() }
        return Array(links.values)
    }
}
