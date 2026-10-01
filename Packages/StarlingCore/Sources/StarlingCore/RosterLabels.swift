import Foundation

/// How a list of people reads wherever the owner reviews whose identifiers
/// leave the phone: the consent sheet and the app's value formatter (review
/// 3 of PR #45). One implementation, so both say the same thing.
public enum RosterLabels {
    /// What an unpaired person is called, before their fingerprint.
    public static let stranger = "someone you haven't paired with"

    /// One label per person, in order. A friend appears by the owner's name
    /// for them. Anyone without a name, and anyone whose label would repeat
    /// in this list (two friends the owner named "Alex"), also gets their
    /// fingerprint, so two different rosters never read the same.
    /// `name` must return the owner's own nickname, never text a peer sent.
    public static func labels(for peers: [PeerID], name: (PeerID) -> String?) -> [String] {
        let names = peers.map { name($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        var counts: [String: Int] = [:]
        for case let label? in names where !label.isEmpty { counts[label.lowercased(), default: 0] += 1 }
        return zip(peers, names).map { peer, label in
            guard let label, !label.isEmpty else { return "\(stranger) (\(peer.fingerprint))" }
            return counts[label.lowercased(), default: 0] > 1 ? "\(label) (\(peer.fingerprint))" : label
        }
    }
}
