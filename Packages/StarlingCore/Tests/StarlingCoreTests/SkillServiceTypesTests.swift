import Foundation
import StarlingCore
import Testing

@Suite struct SkillServiceTypesTests {
    @Test func audiencesRoundTrip() throws {
        for audience in [Audience.allFriends, .closeFriends, .picked([Fixtures.alice, Fixtures.bob])] {
            #expect(try JSONDecoder().decode(Audience.self, from: JSONEncoder().encode(audience)) == audience)
        }
    }

    @Test func aRequestCarriesTheChainForEveryEnvelope() throws {
        let intent = SkillIntent(skill: SkillRef(.pickAPlace, SkillVersion(1)), rules: .empty, audience: .picked([Fixtures.bob]), mode: .invite,
                                 expiresAt: Timestamp(Fixtures.now.addingTimeInterval(3600)))
        let parent = ConversationID()
        let request = SkillRequest(interaction: InteractionID(), conversation: ConversationID(), intent: intent,
                                   participants: [Fixtures.bob], chainedFrom: parent)
        #expect(request.chainedFrom == parent && request.inputs.isEmpty)
    }
}
