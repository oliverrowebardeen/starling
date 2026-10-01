import Foundation
import StarlingCore
import StarlingFeatures
import Testing

/// Codex review of PR #42 (finding 1): both phones must run the ceremony on
/// the same link's PairingService, or neither hears the other.
@Suite struct PairingRouteTests {
    /// What one phone's links report, changing over time.
    final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String: Set<PeerID>]
        init(_ seen: [String: Set<PeerID>]) { self.seen = seen }
        func show(_ peer: PeerID, on link: String) { _ = lock.withLock { seen[link, default: []].insert(peer) } }
        var reachable: @Sendable (String) async -> Set<PeerID> { { [self] link in lock.withLock { seen[link] ?? [] } } }
    }

    let a = PeerID.random()
    let b = PeerID.random()
    let order = ["Wi-Fi Aware", "Nearby"]

    func route(_ peer: PeerID, _ links: Links) async -> String {
        await PairingRoute.link(for: peer, in: order, reachable: links.reachable, waitingUpTo: .milliseconds(300), polling: .milliseconds(10))
    }

    @Test func bothPhonesPickWiFiAwareEvenWhenNearbySawTheFriendFirst() async {
        // Phone A saw B on Nearby only; Wi-Fi Aware reports B a moment later.
        let phoneA = Links(["Nearby": [b]])
        // Phone B already sees A on both.
        let phoneB = Links(["Nearby": [a], "Wi-Fi Aware": [a]])
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            phoneA.show(b, on: "Wi-Fi Aware")
        }
        async let onA = route(b, phoneA)
        async let onB = route(a, phoneB)
        let (linkA, linkB) = await (onA, onB)
        #expect(linkA == "Wi-Fi Aware")
        #expect(linkA == linkB)
    }

    @Test func bothPhonesFallBackToNearbyWhenWiFiAwareNeverSeesTheFriend() async {
        let phoneA = Links(["Nearby": [b]])
        let phoneB = Links(["Nearby": [a]])
        async let onA = route(b, phoneA)
        async let onB = route(a, phoneB)
        let (linkA, linkB) = await (onA, onB)
        #expect(linkA == "Nearby")
        #expect(linkA == linkB)
    }

    @Test func aPhoneWithoutWiFiAwareUsesNearbyAtOnce() async {
        let clock = ContinuousClock()
        let start = clock.now
        let link = await PairingRoute.link(for: b, in: ["Nearby"], reachable: Links(["Nearby": [b]]).reachable,
                                           waitingUpTo: .seconds(5), polling: .milliseconds(10))
        #expect(link == "Nearby")
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
}

@MainActor
@Suite struct PickedDeviceLinkTests {
    /// The picked device pairs on Wi-Fi Aware even if a Nearby candidate for
    /// the same PeerID was listed first, and the list keeps one entry per peer.
    @Test func aPickedDeviceReplacesANearbyCandidateForTheSamePeer() async {
        let peer = PeerID.random()
        var directory = PairingModelTests.scripted().directory
        directory.candidates = { [PairingCandidate(peer: peer, link: "Nearby")] }
        directory.peerForPickedDevice = { _ in peer }
        let model = PairingModel(directory: directory)
        await model.refreshCandidates()
        #expect(model.candidates.first?.link == "Nearby")

        await model.pickedDevice(id: 1, name: "Maya's iPhone")
        #expect(model.selected == PairingCandidate(peer: peer, link: "Wi-Fi Aware"))
        #expect(model.candidates.filter { $0.peer == peer } == [PairingCandidate(peer: peer, link: "Wi-Fi Aware")])

        await model.refreshCandidates()
        #expect(model.candidates.filter { $0.peer == peer }.count == 1, "a refresh does not bring the Nearby duplicate back")
    }
}
