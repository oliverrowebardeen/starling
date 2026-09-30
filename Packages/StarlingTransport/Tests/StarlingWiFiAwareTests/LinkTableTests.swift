import Foundation
import StarlingCore
import StarlingLocalP2P
@testable import StarlingWiFiAware
import Testing

/// Two peers ordered so `high > low`.
private func orderedPeers() -> (high: PeerID, low: PeerID) {
    let a = PeerID.random()
    let b = PeerID.random()
    return a > b ? (a, b) : (b, a)
}

@Suite struct LinkTableRoleTests {
    @Test func dialsUnknownDevicesImmediately() {
        let table = LinkTable(localPeer: .random())
        #expect(table.dialsImmediately(7))
    }

    /// Once both sides know each other, exactly one dials at once, and it is
    /// the side whose outgoing link `LinkArbiter` keeps. Otherwise the waiting
    /// side's fallback would race a link that is about to be preferred.
    @Test(arguments: 0..<50)
    func exactlyOneKnownSideDialsAndItIsThePreferredDialer(seed: Int) {
        let a = PeerID.random()
        let b = PeerID.random()
        var tableA = LinkTable(localPeer: a)
        var tableB = LinkTable(localPeer: b)
        _ = tableA.admit(id: UUID(), peer: b, direction: .outgoing, device: 1)
        _ = tableB.admit(id: UUID(), peer: a, direction: .incoming, device: 2)

        #expect(tableA.dialsImmediately(1) != tableB.dialsImmediately(2))
        #expect(tableA.dialsImmediately(1) == (LinkArbiter.preferredDirection(local: a, remote: b) == .outgoing))
    }
}

@Suite struct LinkTableAdmissionTests {
    @Test func preferredLinkIsActiveAndAnnounced() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let id = UUID()
        let admission = table.admit(id: id, peer: low, direction: .outgoing, device: 1)
        #expect(admission == Admission(state: .active, announce: true))
        #expect(table.activeLink(to: low)?.id == id)
    }

    @Test func nonPreferredLinkIsHeldProvisionalAndNotSendable() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let admission = table.admit(id: UUID(), peer: low, direction: .incoming, device: 1)
        #expect(admission == Admission(state: .provisional, announce: false))
        #expect(table.activeLink(to: low) == nil)
        #expect(table.isLinked(1))
    }

    @Test func preferredLinkReplacesProvisionalOneAndAnnounces() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: low)
        let provisional = UUID()
        _ = table.admit(id: provisional, peer: high, direction: .outgoing, device: 1)
        let preferred = UUID()
        let admission = table.admit(id: preferred, peer: high, direction: .incoming, device: 1)
        #expect(admission == Admission(state: .active, announce: true, closed: [provisional]))
        #expect(table.activeLink(to: high)?.id == preferred)
    }

    @Test func nonPreferredLinkLosesToActivePreferredOne() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let preferred = UUID()
        _ = table.admit(id: preferred, peer: low, direction: .outgoing, device: 1)
        let admission = table.admit(id: UUID(), peer: low, direction: .incoming, device: 1)
        #expect(admission.state == nil)
        #expect(table.activeLink(to: low)?.id == preferred)
    }

    @Test func activatedProvisionalLinkIsReplacedByPreferredWithoutReannouncing() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let provisional = UUID()
        _ = table.admit(id: provisional, peer: low, direction: .incoming, device: 1)
        let promoted = table.activate(provisional)
        let promotedTwice = table.activate(provisional)
        #expect(promoted)
        #expect(!promotedTwice)
        let admission = table.admit(id: UUID(), peer: low, direction: .outgoing, device: 1)
        #expect(admission == Admission(state: .active, announce: false, closed: [provisional]))
    }

    /// A peer that restarted redials while our old link has not noticed yet.
    @Test func sameDirectionRedialReplacesTheOldLinkAndKeepsTheStateActive() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let old = UUID()
        _ = table.admit(id: old, peer: low, direction: .incoming, device: 1)
        _ = table.activate(old)
        let new = UUID()
        let admission = table.admit(id: new, peer: low, direction: .incoming, device: 1)
        #expect(admission == Admission(state: .active, announce: false, closed: [old]))
        #expect(table.activeLink(to: low)?.id == new)
    }

    @Test func oneLinkPerDevice() {
        let local = PeerID.random()
        let first = PeerID.random()
        let second = PeerID.random()
        var table = LinkTable(localPeer: local)
        let firstLink = UUID()
        let firstState = table.admit(id: firstLink, peer: first, direction: .outgoing, device: 1).state
        if firstState == .provisional { _ = table.activate(firstLink) }

        let admission = table.admit(id: UUID(), peer: second, direction: .outgoing, device: 1)
        #expect(admission.closed == [firstLink])
        #expect(admission.unavailable == [first])
        #expect(table.links[first] == nil)
        #expect(table.peersByDevice[1] == second)
    }

    @Test func rejectsOurOwnPeerID() {
        let local = PeerID.random()
        var table = LinkTable(localPeer: local)
        let admission = table.admit(id: UUID(), peer: local, direction: .incoming, device: 1)
        #expect(admission.state == nil)
        #expect(table.links.isEmpty)
    }

    @Test func removeOnlyForgetsTheCurrentLink() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let replaced = UUID()
        _ = table.admit(id: replaced, peer: low, direction: .incoming, device: 1)
        let current = UUID()
        _ = table.admit(id: current, peer: low, direction: .outgoing, device: 1)

        let removedReplaced = table.remove(replaced)
        let removedCurrent = table.remove(current)
        #expect(removedReplaced == nil)
        #expect(removedCurrent?.peer == low)
        #expect(table.links.isEmpty)
        // The mapping outlives the link, so the redial knows its role.
        #expect(table.device(for: low) == 1)
        #expect(!table.isLinked(1))
    }

    @Test func incomingLinkWithoutDeviceStillCountsForItsLearnedDevice() {
        let (high, low) = orderedPeers()
        var table = LinkTable(localPeer: high)
        let dialed = UUID()
        _ = table.admit(id: dialed, peer: low, direction: .outgoing, device: 3)
        _ = table.remove(dialed)
        _ = table.admit(id: UUID(), peer: low, direction: .incoming, device: nil)
        #expect(table.isLinked(3))
        #expect(table.device(for: low) == 3)
    }
}
