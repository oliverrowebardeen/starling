import Foundation
import StarlingCore
import StarlingPolicy
import Testing

/// Lane E's request: Outbox asks the policy, through the protocol, what a
/// send it allowed disclosed. The deterministic engine must answer with its
/// own items, not the protocol's "cannot say" default.
@Suite struct DisclosureThroughTheProtocolTests {
    @Test func theDeterministicEngineSaysWhatAnAllowedSendDisclosed() async throws {
        let engine: any PolicyEngine = Fixtures.engine(action: .allowOnDevicePeers)
        let message = try Fixtures.outbound(Fixtures.body(.propose))
        #expect(await engine.evaluate(message) == .allow)
        let items = try await engine.disclosedItems(for: message)
        #expect(items == (try Fixtures.engine().disclosure(for: message).items))
        #expect(items.contains { $0.issue == .activity })
    }
}
