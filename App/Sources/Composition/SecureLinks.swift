import Foundation
import StarlingCore
import StarlingFeatures
import StarlingIdentity
import StarlingLocalP2P
import StarlingWiFiAware

/// The app's links on lane E1's secure channel (docs/requests/E1.md item 2):
/// one identity, one PinAuthority shared by every SecureTransport and
/// PairingService, LocalP2P and (where it runs) Wi-Fi Aware, merged behind
/// one Outbox and one Inbox (ADR 0145).
struct SecureLinks: Sendable {
    struct Link: Sendable {
        let label: String
        let watcher: LinkWatcher
        let secure: SecureTransport
        let pairing: PairingService
    }

    let identity: IdentityKeyPair
    let friends: any PairedPeerStore
    let authority: PinAuthority
    let links: [Link]
    /// The raw Wi-Fi Aware link, for lane E2's picked-device lookup.
    let wifiAware: WiFiAwareTransport?
    let transport: CompositeTransport
    let inboxEvents: AsyncStream<InboxEvent>

    /// - Parameters:
    ///   - identity: This phone's identity (`KeychainIdentityKeyStore`).
    ///   - friends: The pinned friends (`KeychainPairedPeerStore`). Only the
    ///     authority may change it.
    ///   - extraLinks: More raw links with this identity's PeerID, for
    ///     example Debug's in-process Loopback link.
    static func make(identity: IdentityKeyPair, friends: any PairedPeerStore, extraLinks: [(String, any Transport)] = []) -> SecureLinks {
        // Exactly one authority for the app: a second one over the same
        // store would let an unpair through one transport miss the other's
        // sessions and commits (ADR 0100 decision 11).
        let authority = PinAuthority(identity: identity, store: friends)
        var raw: [(String, any Transport)] = []
        let wifiAware = WiFiAwareSupport.isSupported ? WiFiAwareTransport(localPeer: identity.peerID) : nil
        if let wifiAware { raw.append(("Wi-Fi Aware", wifiAware)) }
        raw.append(("Nearby", LocalP2PTransport(localPeer: identity.peerID)))
        raw += extraLinks
        let links = raw.map { label, transport in
            let watcher = LinkWatcher(wrapping: transport)
            let secure = SecureTransport(wrapping: watcher, authority: authority)
            return Link(label: label, watcher: watcher, secure: secure, pairing: PairingService(secureTransport: secure))
        }
        let transport = CompositeTransport(links: links.map(\.secure))
        return SecureLinks(
            identity: identity,
            friends: friends,
            authority: authority,
            links: links,
            wifiAware: wifiAware,
            transport: transport,
            inboxEvents: Inbox(localPeer: identity.peerID).events(from: transport)
        )
    }

    /// Starts each pairing service after its secure transport has started.
    /// The services must live as long as the app: their event loops hold
    /// them weakly. This closure, kept by AppServices, holds them.
    var startPairing: @Sendable () async -> Void {
        let links = links
        return {
            for link in links { try? await link.pairing.start() }
        }
    }

    /// Unpairs through the one authority: ends the friend's sessions on
    /// every transport, cancels any ceremony with them, removes the pin.
    var unpair: @Sendable (PeerID) async throws -> Void {
        let authority = authority
        return { try await authority.unpair($0) }
    }

    var pairingDirectory: PairingDirectory {
        let links = links
        var peerForPickedDevice: (@Sendable (UInt64) async -> PeerID?)?
        if let aware = wifiAware {
            peerForPickedDevice = { id in
                await aware.peerID(for: WiFiAwarePairedDevice(id: id, name: ""), waitingUpTo: .seconds(15))
            }
        }
        let friends = friends
        let me = identity.peerID
        return PairingDirectory(
            localPeer: me,
            candidates: {
                let pinned = Set(((try? await friends.all()) ?? []).map(\.id))
                var seen: Set<PeerID> = []
                var candidates: [PairingCandidate] = []
                for link in links {
                    for peer in await link.watcher.reachablePeers().sorted() where peer != me && !pinned.contains(peer) && seen.insert(peer).inserted {
                        candidates.append(PairingCandidate(peer: peer, link: link.label))
                    }
                }
                return candidates
            },
            pair: { candidate, nickname in
                guard let link = links.first(where: { $0.label == candidate.link }) ?? links.first else {
                    throw TransportError.peerUnreachable(candidate.peer)
                }
                return try await link.pairing.pair(with: candidate.peer, nickname: nickname)
            },
            paired: { peer in
                // E1: on .paired, reconnect on each transport.
                for link in links { await link.secure.reconnect(peer.id) }
            },
            // Lane E2 (PR #38): the PeerID behind the device the owner picked,
            // waiting for its link hello, which follows the system pairing.
            peerForPickedDevice: peerForPickedDevice
        )
    }
}
