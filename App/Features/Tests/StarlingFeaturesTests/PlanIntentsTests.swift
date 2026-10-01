import AppIntents
import Foundation
@testable import StarlingFeatures
import Testing

@Suite struct PlanIntentsTests {
    /// Review of PR #54, finding 1: nothing that reads plans or names runs
    /// on a locked phone. `alwaysAllowed` is the framework's default.
    @Test func everyPlanIntentRequiresAnUnlockedPhone() {
        #expect(!StarlingIntents.readingPersonalData.isEmpty)
        for intent in StarlingIntents.readingPersonalData {
            #expect(intent.authenticationPolicy == .requiresLocalDeviceAuthentication, "\(intent)")
        }
    }
}
