import StarlingCore

/// Which link's PairingService runs a ceremony with a peer. Lane E1's
/// ceremonies listen on one link each, so both phones must choose the same
/// link or neither hears the other (Codex review of PR #42, finding 1).
///
/// The rule is the same on every phone: the first link in `order` (Wi-Fi
/// Aware) once it reports the peer, waiting up to `waitingUpTo` for it;
/// otherwise the first link that reports the peer; otherwise the first link.
/// Two phones that can reach each other over Wi-Fi Aware therefore both use
/// it, even if LocalP2P found the friend first on one of them.
public enum PairingRoute {
    public static func link(
        for peer: PeerID,
        in order: [String],
        reachable: @Sendable (String) async -> Set<PeerID>,
        waitingUpTo timeout: Duration = .seconds(5),
        polling interval: Duration = .milliseconds(200)
    ) async -> String {
        guard let preferred = order.first else { return "" }
        if order.count > 1 {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await reachable(preferred).contains(peer) { return preferred }
                try? await Task.sleep(for: interval)
            }
        }
        for link in order where await reachable(link).contains(peer) { return link }
        return preferred
    }
}
