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

    @Test func requiresOnlyPlace() throws {
        // ADR 0019, decision 7: organizing sends venue options, so place is
        // required; budget, diet, and location are used on the phone only.
        #expect(descriptor.topicsRequired == [.place])
        #expect(descriptor.topicsUsed.isSuperset(of: [.place, .location, .budget, .diet, .people]))
        var privacy = PrivacySettings()
        try privacy.set(.never, for: .place)
        #expect(descriptor.blockingTopics(in: privacy) == [.place])
        try privacy.set(.share, for: .place)
        for topic in [PrivacyTopic.budget, .diet, .location, .people] { try privacy.set(.never, for: topic) }
        #expect(descriptor.blockingTopics(in: privacy).isEmpty)
        #expect(descriptor.blockingTopics(in: .defaults).isEmpty)
    }

    @Test func asksForNoExpiry() {
        // Compose hides the expiry chip and keeps the request open until
        // the plan's time (the owner's device test, 2026-10-02).
        #expect(descriptor.intent.asksForExpiry == false)
        #expect(descriptor.intent.asksForAudience)
    }

    @Test func sendsOnlyAsAnInvite() {
        #expect(descriptor.sendModes == [.invite])
        #expect(descriptor.defaultSendMode == .invite)
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
