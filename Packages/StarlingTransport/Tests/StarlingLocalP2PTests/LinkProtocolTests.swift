import Foundation
import StarlingCore
@testable import StarlingLocalP2P
import Testing

@Suite struct LinkHelloTests {
    @Test func roundTrips() throws {
        let hello = try LinkHello(peer: .random(), serviceName: ServiceName.random())
        #expect(try LinkHello(decoding: hello.encoded) == hello)
    }

    @Test func rejectsEmptyOrOversizedServiceNames() {
        #expect(throws: ValidationError.self) { try LinkHello(peer: .random(), serviceName: "") }
        #expect(throws: ValidationError.self) { try LinkHello(peer: .random(), serviceName: String(repeating: "a", count: 64)) }
    }

    @Test func rejectsBadMagicVersionAndLength() throws {
        var bytes = [UInt8](try LinkHello(peer: .random(), serviceName: "starling-abc").encoded)
        #expect(throws: ValidationError.self) { try LinkHello(decoding: Data(bytes + [0x41])) }
        #expect(throws: ValidationError.self) { try LinkHello(decoding: Data(bytes.dropLast())) }
        bytes[4] = 9
        #expect(throws: ValidationError.self) { try LinkHello(decoding: Data(bytes)) }
        bytes[4] = LinkHello.version
        bytes[0] = UInt8(ascii: "X")
        #expect(throws: ValidationError.self) { try LinkHello(decoding: Data(bytes)) }
    }
}

@Suite struct DialRuleTests {
    @Test func exactlyOneSideDialsImmediately() {
        for _ in 0..<50 {
            let a = ServiceName.random()
            let b = ServiceName.random()
            let aDials = DialRule.shouldDialImmediately(ownServiceName: a, discovered: b)
            let bDials = DialRule.shouldDialImmediately(ownServiceName: b, discovered: a)
            #expect(aDials != bDials)
        }
    }
}

@Suite struct DiscoveryTests {
    /// A browser update lists every advertised service. Only services absent
    /// from the previous update may start a dial; one whose retries ran out
    /// must not be redialed just because another phone appeared.
    @Test func onlyNewlyDiscoveredServicesStartADial() {
        #expect(Discovery.newlyDiscovered(previous: [], current: ["a", "b"]) == ["a", "b"])
        #expect(Discovery.newlyDiscovered(previous: ["a"], current: ["a", "c"]) == ["c"])
        #expect(Discovery.newlyDiscovered(previous: ["a", "b"], current: ["b"]).isEmpty)
        // A service that disappeared and came back counts as new again.
        #expect(Discovery.newlyDiscovered(previous: ["b"], current: ["a", "b"]) == ["a"])
    }
}

@Suite struct RetryPolicyTests {
    @Test func backsOffThenGivesUp() {
        let delays = (1...RetryPolicy.maxAttempts).map { RetryPolicy.delay(forAttempt: $0) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        #expect(RetryPolicy.delay(forAttempt: 0) == nil)
        #expect(RetryPolicy.delay(forAttempt: RetryPolicy.maxAttempts + 1) == nil)
    }
}

@Suite struct LinkArbiterTests {
    /// The connection A dials to B is outgoing for A and incoming for B. Both
    /// sides must keep that same connection, or they each drop the other's
    /// survivor and end up with nothing.
    @Test(arguments: 0..<50)
    func bothSidesKeepTheSameConnection(seed: Int) {
        let a = PeerID.random()
        let b = PeerID.random()
        let aKeepsItsOutgoing = LinkArbiter.preferredDirection(local: a, remote: b) == .outgoing
        let bKeepsItsIncoming = LinkArbiter.preferredDirection(local: b, remote: a) == .incoming
        #expect(aKeepsItsOutgoing == bKeepsItsIncoming)
    }

    @Test func replacesOnlyWithThePreferredDirection() {
        let high = try! PeerID(bytes: Data(repeating: 0xFF, count: 32))
        let low = try! PeerID(bytes: Data(repeating: 0x00, count: 32))
        #expect(LinkArbiter.shouldReplace(existing: .incoming, with: .outgoing, local: high, remote: low))
        #expect(!LinkArbiter.shouldReplace(existing: .outgoing, with: .incoming, local: high, remote: low))
        #expect(!LinkArbiter.shouldReplace(existing: .outgoing, with: .outgoing, local: high, remote: low))
        #expect(LinkArbiter.shouldReplace(existing: .outgoing, with: .incoming, local: low, remote: high))
    }
}

@Suite struct ServiceNameTests {
    @Test func isRandomShortAndNotIdentifying() {
        let a = ServiceName.random()
        let b = ServiceName.random()
        #expect(a != b)
        #expect(a.hasPrefix("starling-"))
        #expect(a.utf8.count <= 63) // DNS-SD instance name limit
    }
}
