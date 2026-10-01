import Foundation
import StarlingCore
import Testing

@Suite struct AgentCardSkillsTests {
    @Test func aPhaseOneCardDecodesWithNoSkills() throws {
        // A Phase 1 card is today's encoding without the "skills" key.
        var fields = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AgentCard(model: .onDevice, capabilities: [.down, .psi]))
        ) as? [String: Any])
        #expect(fields.removeValue(forKey: "skills") != nil)
        let phase1 = try JSONSerialization.data(withJSONObject: fields)
        let card = try JSONDecoder().decode(AgentCard.self, from: phase1)
        #expect(card.skills.isEmpty)
        #expect(card.support(for: SkillRef(.downFor, SkillVersion(1))) == .missing)
    }

    @Test func skillsRoundTripAndAreBounded() throws {
        let card = try AgentCard(model: .onDevice, capabilities: [.psi],
                                 skills: [SkillRef(.downFor, SkillVersion(1, 2)), SkillRef(.findATime, SkillVersion(1))])
        #expect(try JSONDecoder().decode(AgentCard.self, from: JSONEncoder().encode(card)) == card)
        #expect(throws: ValidationError.self) {
            try AgentCard(model: .onDevice, capabilities: [], skills: [SkillRef(.downFor, SkillVersion(1)), SkillRef(.downFor, SkillVersion(2))])
        }
        let many = try (0...ProtocolLimits.maxSkillsAdvertised).map { SkillRef(try SkillID("s\($0)"), SkillVersion(1)) }
        #expect(throws: ValidationError.self) { try AgentCard(model: .onDevice, capabilities: [], skills: many) }
    }

    @Test func supportComparesMajorVersions() throws {
        let card = try AgentCard(model: .onDevice, capabilities: [], skills: [SkillRef(.pickAPlace, SkillVersion(1, 4))])
        #expect(card.support(for: SkillRef(.pickAPlace, SkillVersion(1, 0))) == .supported(SkillVersion(1, 4)))
        #expect(card.support(for: SkillRef(.pickAPlace, SkillVersion(2, 0))) == .incompatible(SkillVersion(1, 4)))
        #expect(card.support(for: SkillRef(.swapPhotos, SkillVersion(1))) == .missing)
        #expect(!SkillSupport.missing.isSupported)
    }
}
