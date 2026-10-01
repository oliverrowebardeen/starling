import Foundation

/// How a list of people reads wherever the owner reviews whose identifiers
/// leave the phone: the consent sheet and the app's value formatter (reviews
/// 3 and 4 of PR #45). One implementation, so both say the same thing.
public enum RosterLabels {
    /// What an unpaired person is called, before their identifier.
    public static let stranger = "someone you haven't paired with"

    /// One label per person, in order.
    ///
    /// - A friend appears by the owner's name for them. If the owner gave
    ///   that name to more than one friend, or it contains a parenthesis,
    ///   the label adds the friend's fingerprint, so a roster with one Alex
    ///   never reads like a roster with the other, and no name can imitate
    ///   another friend's label. A friend's ID is the hash of a key pinned at
    ///   pairing, so 64 bits of it tell friends apart.
    /// - Anyone else appears with their full identifier: a roster entry is
    ///   an unverified 32-byte value a peer chose, so no prefix of it is
    ///   safe to show alone.
    ///
    /// - Parameter friends: Every paired friend and the owner's name for
    ///   them, never text a peer sent.
    public static func labels(for peers: [PeerID], friends: [PeerID: String]) -> [String] {
        var holders: [String: Int] = [:]
        for name in friends.values { holders[key(name), default: 0] += 1 }
        return peers.map { peer in
            guard let name = friends[peer]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return "\(stranger) (\(fullIdentifier(peer)))"
            }
            return needsFingerprint(name, holders: holders) ? "\(name) (\(peer.fingerprint))" : name
        }
    }

    /// A shared nickname, or one containing a parenthesis, which could
    /// imitate another friend's generated "Name (fingerprint)" label
    /// (review 5 of PR #45).
    private static func needsFingerprint(_ name: String, holders: [String: Int]) -> Bool {
        holders[key(name), default: 0] > 1 || name.contains("(") || name.contains(")")
    }

    /// All 64 hex characters in groups of four.
    public static func fullIdentifier(_ peer: PeerID) -> String {
        let digits = Array(peer.hex)
        return stride(from: 0, to: digits.count, by: 4).map { String(digits[$0..<min($0 + 4, digits.count)]) }.joined(separator: " ")
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
