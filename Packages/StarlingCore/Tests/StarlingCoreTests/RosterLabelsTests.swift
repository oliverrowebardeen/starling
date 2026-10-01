import Foundation
import StarlingCore
import Testing

@Suite struct RosterLabelsTests {
    @Test func friendsByNameAndStrangersByFingerprint() throws {
        let stranger = PeerID.random()
        let labels = RosterLabels.labels(for: [Fixtures.alice, stranger]) { $0 == Fixtures.alice ? "Maya" : nil }
        #expect(labels == ["Maya", "\(RosterLabels.stranger) (\(stranger.fingerprint))"])
        #expect(stranger.fingerprint.count == 19 && stranger.fingerprint.split(separator: " ").count == 4)
    }

    /// Review 3 of PR #45: two friends both named Alex.
    @Test func duplicateNicknamesAreDisambiguated() throws {
        let alexA = PeerID.random(), alexB = PeerID.random()
        let names: [PeerID: String] = [Fixtures.alice: "Maya", alexA: "Alex", alexB: "alex "]
        let one = RosterLabels.labels(for: [Fixtures.alice, alexA, alexB]) { names[$0] }
        #expect(one[0] == "Maya")
        #expect(one[1] == "Alex (\(alexA.fingerprint))" && one[2] == "alex (\(alexB.fingerprint))")
    }

    /// Review 3 of PR #45: IDs that share their first eight hex characters.
    @Test func sharedShortPrefixesStillReadDifferently() throws {
        var a = [UInt8](repeating: 0xAB, count: 32), b = a
        b[5] = 0x01
        let first = try PeerID(bytes: Data(a)), second = try PeerID(bytes: Data(b))
        #expect(first.short == second.short)
        #expect(RosterLabels.labels(for: [first]) { _ in nil } != RosterLabels.labels(for: [second]) { _ in nil })
    }
}
