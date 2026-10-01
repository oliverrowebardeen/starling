import PickAPlace
import StarlingCore
import StarlingFakes
import Testing

@Suite("Descriptor")
struct DescriptorTests {
    let descriptor = PickAPlaceSkill.descriptor

    @Test func isPickAPlaceVersionOne() {
        #expect(descriptor.ref == SkillRef(.pickAPlace, SkillVersion(1, 0)))
        #expect(descriptor.ref == SampleSkills.pickAPlace.ref)
        #expect(descriptor.buildingBlock == .privateAggregation)
    }

    @Test func acceptsAPlanOrATimeAndProducesAPlace() {
        #expect(descriptor.accepts == [.plan, .timeSlot])
        #expect(descriptor.produces == [.placeChoice, .attendees])
        #expect(descriptor.canFollow(SampleSkills.downFor))
        #expect(descriptor.canFollow(SampleSkills.findATime))
        #expect(!descriptor.canFollow(SampleSkills.swapPhotos))
    }

    @Test func asksForLocationOnlyAsAPermissionItMayNeed() {
        #expect(descriptor.permissions == [.locationWhenInUse])
    }

    @Test func requiresPlaceAndPeople() throws {
        #expect(descriptor.topicsRequired == [.place, .people])
        var privacy = PrivacySettings()
        try privacy.set(.never, for: .place)
        #expect(descriptor.blockingTopics(in: privacy) == [.place])
        try privacy.set(.share, for: .place)
        try privacy.set(.never, for: .budget)
        try privacy.set(.never, for: .diet)
        // Budget and diet never leave the phone, so Never on them does not
        // block the skill.
        #expect(descriptor.blockingTopics(in: privacy).isEmpty)
    }

    @Test func registersBesideTheOtherSkills() throws {
        let registry = try SkillRegistry([SampleSkills.downFor, SampleSkills.findATime, descriptor])
        let settings = SkillSettings(flags: .phase1_5)
        #expect(registry.availability(of: .pickAPlace, in: settings) == .available)
        let suggestions = registry.chainSuggestions(after: .downFor, in: settings, peers: [])
        #expect(suggestions.map(\.id) == [.pickAPlace])
    }

    @Test func wordingReadsAsPlans() {
        #expect(descriptor.wording.name == "Pick a place")
        #expect(descriptor.wording.startAction == "Find a place")
        #expect(descriptor.wording.declineNote == "If you pass, they just won't see it.")
    }
}
