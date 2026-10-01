import CryptoKit
import Foundation
import StarlingCore

/// The PSI set for "may these friends share a plan with you?" (ADR 0210,
/// decision 22): one token per friend, a hash of a fixed prefix and the
/// friend's `PeerID`, padded with random tokens to a fixed size so the set
/// size says nothing about how many friends are in it.
///
/// The starter's set holds the other friends who answered it; a member's
/// set holds the friends its own request includes. The starter, as PSI
/// initiator, learns which of its candidates the member's request includes;
/// with a private PSI provider the member learns nothing (with the
/// insecure stub it learns the starter's candidates, which the consent
/// sheet says while the stub is in use).
struct FriendTokens: Sendable {
    /// The starter's side: at most 15 other friends (16 people in a plan).
    static let starterSetSize = ProtocolLimits.maxAttendees - 1
    /// A member's side: its request's friends, at most this many.
    static let memberSetSize = 64
    private static let prefix = Data("starling/down_for/v1/friend/".utf8)

    let elements: Set<PSIElement>
    private let friendsByToken: [PSIElement: PeerID]

    init(_ friends: [PeerID], size: Int) {
        let kept = Array(friends.prefix(size))
        friendsByToken = Dictionary(kept.map { (Self.token(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        var elements = Set(friendsByToken.keys)
        var generator = SystemRandomNumberGenerator()
        while elements.count < size {
            // Force-try is safe: 32 bytes.
            elements.insert(try! PSIElement(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })))
        }
        self.elements = elements
    }

    static func token(for friend: PeerID) -> PSIElement {
        // Force-try is safe: a SHA-256 digest is 32 bytes.
        try! PSIElement(Data(SHA256.hash(data: prefix + friend.bytes)))
    }

    func friends(in shared: Set<PSIElement>) -> Set<PeerID> {
        Set(shared.compactMap { friendsByToken[$0] })
    }

    /// The starter learns the shared friends; a member's set may be larger
    /// than the starter's, so each side bounds the other's.
    static func starterConfiguration() throws -> PSIConfiguration {
        try PSIConfiguration(output: .intersection, maxPeerSetSize: memberSetSize, maxLocalSetSize: starterSetSize)
    }

    static func memberConfiguration() throws -> PSIConfiguration {
        try PSIConfiguration(output: .intersection, maxPeerSetSize: starterSetSize, maxLocalSetSize: memberSetSize)
    }
}
