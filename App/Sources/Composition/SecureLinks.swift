import Foundation
import StarlingCore
import StarlingFeatures
import StarlingIdentity
import StarlingLocalP2P
import StarlingWiFiAware

/// The app's links on lane E1's secure channel (docs/requests/E1.md item 2):
/// one identity, one PinAuthority shared by every SecureTransport and the
/// PairingService, LocalP2P and (where it runs) Wi-Fi Aware, merged behind
/// one Outbox and one Inbox (ADR 0145). One PairingService runs over every
/// link at once, so two phones pair on whichever link reaches (ADR 0260).
struct SecureLinks: Sendable {
    struct Link: Sendable {
        let label: String
        let watcher: LinkWatcher
        let secure: SecureTransport
    }

    let identity: IdentityKeyPair
    let friends: any PairedPeerStore
    let authority: PinAuthority
    let links: [Link]
    let pairing: PairingService
    /// The raw Wi-Fi Aware link, for the picked device and device names.
    let wifiAware: WiFiAwareTransport?
    let transport: CompositeTransport
    let inboxEvents: AsyncStream<InboxEvent>

    /// - Parameters:
    ///   - identity: This phone's identity (`KeychainIdentityKeyStore`).
    ///   - friends: The pinned friends (`KeychainPairedPeerStore`). Only the
    ///     authority may change it.
    ///   - extraLinks: More raw links with this identity's PeerID, for
    ///     example Debug's in-process Loopback link.
    ///   - log: Debug builds only: the pairing log (ADR 0260).
    static func make(identity: IdentityKeyPair, friends: any PairedPeerStore, extraLinks: [(String, any Transport)] = [], log: PairingLog? = nil) -> SecureLinks {
        // Exactly one authority for the app: a second one over the same
        // store would let an unpair through one transport miss the other's
        // sessions and commits (ADR 0100 decision 11).
        let authority = PinAuthority(identity: identity, store: friends)
        var raw: [(String, any Transport)] = []
        let wifiAware = WiFiAwareSupport.isSupported ? WiFiAwareTransport(localPeer: identity.peerID, trace: log?.recorder(source: "Wi-Fi Aware")) : nil
        if let wifiAware { raw.append(("Wi-Fi Aware", wifiAware)) }
        raw.append(("Nearby", LocalP2PTransport(localPeer: identity.peerID)))
        raw += extraLinks
        let links = raw.map { label, transport in
            let watcher = LinkWatcher(wrapping: transport)
            return Link(label: label, watcher: watcher, secure: SecureTransport(wrapping: watcher, authority: authority))
        }
        var trace: (@Sendable (PairingTrace) -> Void)?
        if let record = log?.recorder(source: "Pairing") {
            trace = { step in record(step.description) }
        }
        let pairing = PairingService(authority: authority, links: links.map(\.secure.pairingLink), trace: trace)
        let transport = CompositeTransport(links: links.map(\.secure))
        return SecureLinks(
            identity: identity,
            friends: friends,
            authority: authority,
            links: links,
            pairing: pairing,
            wifiAware: wifiAware,
            transport: transport,
            inboxEvents: Inbox(localPeer: identity.peerID).events(from: transport)
        )
    }

    /// Starts the pairing service after the secure transports have started.
    /// It must live as long as the app: its event loops hold it weakly.
    /// This closure, kept by AppServices, holds it.
    var startPairing: @Sendable () async -> Void {
        let pairing = pairing
        return { try? await pairing.start() }
    }

    /// Unpairs through the one authority: ends the friend's sessions on
    /// every transport, cancels any ceremony with them, removes the pin.
    var unpair: @Sendable (PeerID) async throws -> Void {
        let authority = authority
        return { try await authority.unpair($0) }
    }

    /// Renames through the one authority (lane E1, #36): under the pin lock,
    /// refusing a friend that is being unpaired, so it can never write back
    /// a pin an unpair removed.
    var rename: @Sendable (PeerID, String) async throws -> Void {
        let authority = authority
        return { try await authority.rename($0, to: $1) }
    }

    var pairingDirectory: PairingDirectory {
        let links = links
        let pairing = pairing
        let aware = wifiAware
        var peerForPickedDevice: (@Sendable (UInt64) async -> PeerID?)?
        if let aware {
            peerForPickedDevice = { id in
                let device = WiFiAwarePairedDevice(id: id, name: "")
                // This phone picked: it subscribes and dials (ADR 0260).
                await aware.pickedDevice(device)
                return await aware.peerID(for: device, waitingUpTo: .seconds(30))
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
                        candidates.append(PairingCandidate(peer: peer, deviceName: await aware?.pairedDevice(for: peer)?.name))
                    }
                }
                return candidates
            },
            requests: { await pairing.requests() },
            pair: { peer, nickname in try await pairing.pair(with: peer, nickname: nickname) },
            paired: { peer in
                // E1: on .paired, reconnect on each transport.
                for link in links { await link.secure.reconnect(peer.id) }
            },
            rename: rename,
            deviceName: { peer in await aware?.pairedDevice(for: peer)?.name },
            opened: { await aware?.expectPairing() },
            peerForPickedDevice: peerForPickedDevice
        )
    }
}
