import Foundation
@testable import PeerKit
import StarlingCore
import StarlingTransport
import Testing

@Suite struct PeerSessionTests {
    /// Waits for a log line containing `text`.
    func waitForLine(_ text: String, in session: PeerSession) async -> Bool {
        for await line in session.log where line.contains(text) { return true }
        return false
    }

    @Test(.timeLimit(.minutes(1)))
    func proposalIsAutoAcceptedAndTimed() async throws {
        let hub = LoopbackHub()
        let mac = PeerSession(transport: LoopbackTransport(hub: hub))
        let phone = PeerSession(transport: LoopbackTransport(hub: hub))
        try await mac.start()
        try await phone.start()
        #expect(await waitForLine("Found \(phone.me.short)", in: mac))

        try await mac.sendProposal(to: "1")
        #expect(await waitForLine("round trip", in: mac))
        #expect(await mac.roundTrips.count == 1)
        await mac.stop()
        await phone.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func selectsPeersByNumberOrPrefix() async throws {
        let hub = LoopbackHub()
        let mac = PeerSession(transport: LoopbackTransport(hub: hub))
        let phone = PeerSession(transport: LoopbackTransport(hub: hub))
        try await mac.start()
        try await phone.start()
        #expect(await waitForLine("Found", in: mac))

        try await mac.sendProposal(to: String(phone.me.hex.prefix(6)))
        await #expect(throws: PeerSession.PeerError.noSuchPeer("9")) { try await mac.sendProposal(to: "9") }
        await #expect(throws: PeerSession.PeerError.noSuchPeer("")) { try await mac.sendProposal(to: "") }
        #expect(await mac.describePeers() == ["1) \(phone.me.short)"])
        await mac.stop()
        await phone.stop()
    }

    @Test func summarizesRoundTripsWithATrueMedian() {
        #expect(PeerSession.summarize([]) == nil)
        #expect(PeerSession.summarize([.milliseconds(4), .milliseconds(2)]) == "2 round trips: min 2.0 ms, median 3.0 ms, max 4.0 ms")
        #expect(PeerSession.summarize([.milliseconds(9), .milliseconds(1), .milliseconds(5)]) == "3 round trips: min 1.0 ms, median 5.0 ms, max 9.0 ms")
    }

    @Test func sampleProposalMatchesTheApp() throws {
        let terms = try PeerSession.sampleProposal().terms
        #expect(terms[.activity] == .keywords([try Keyword("boba")]))
        #expect(terms[.budget] == .amount(try MoneyAmount(minorUnits: 1200)))
    }
}
