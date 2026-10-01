import Foundation
import StarlingCore
import Testing

@Suite struct RosterLabelsTests {
    @Test func friendsByNameAndStrangersInFull() throws {
        let stranger = PeerID.random()
        let labels = RosterLabels.labels(for: [Fixtures.alice, stranger], friends: [Fixtures.alice: "Maya"])
        #expect(labels[0] == "Maya")
        #expect(labels[1] == "\(RosterLabels.stranger) (\(RosterLabels.fullIdentifier(stranger)))")
        #expect(RosterLabels.fullIdentifier(stranger).replacingOccurrences(of: " ", with: "") == stranger.hex)
    }

    /// Review 4 of PR #45: two friends named Alex, and a roster with only one.
    @Test func aNicknameSharedByTwoFriendsIsAlwaysDisambiguated() throws {
        let alexA = PeerID.random(), alexB = PeerID.random()
        let friends: [PeerID: String] = [Fixtures.alice: "Maya", alexA: "Alex", alexB: "alex "]
        let withA = RosterLabels.labels(for: [Fixtures.alice, alexA], friends: friends)
        let withB = RosterLabels.labels(for: [Fixtures.alice, alexB], friends: friends)
        #expect(withA != withB)
        #expect(withA == ["Maya", "Alex (\(alexA.fingerprint))"])
        // A unique name needs nothing more.
        #expect(RosterLabels.labels(for: [Fixtures.alice], friends: friends) == ["Maya"])
    }

    /// Review 4 of PR #45: unverified IDs that agree on their first 16 hex
    /// characters must still read differently.
    @Test func strangersWhoShareAPrefixStillReadDifferently() throws {
        var a = [UInt8](repeating: 0xAB, count: 32), b = a
        b[8] = 0x01
        let first = try PeerID(bytes: Data(a)), second = try PeerID(bytes: Data(b))
        #expect(first.fingerprint == second.fingerprint)
        #expect(RosterLabels.labels(for: [first], friends: [:]) != RosterLabels.labels(for: [second], friends: [:]))
    }
}
