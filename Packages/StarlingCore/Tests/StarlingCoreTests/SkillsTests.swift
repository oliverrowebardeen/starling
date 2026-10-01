import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct SkillsTests {
    static let wording = SkillWording(
        name: "Down for…", summary: "See who's up for something", startAction: "See who's up for it",
        acceptAction: "I'm in", declineAction: "Not tonight", declineNote: "If you pass, they just won't see it."
    )

    static func descriptor(
        _ id: SkillID = .downFor,
        used: Set<PrivacyTopic> = [.time, .activity, .place],
        required: Set<PrivacyTopic> = [.time, .activity],
        permissions: Set<SystemPermission> = [],
        accepts: Set<ArtifactKind> = [],
        produces: Set<ArtifactKind> = [.plan],
        slots: [IntentSlot]? = nil
    ) throws -> SkillDescriptor {
        try SkillDescriptor(
            ref: SkillRef(id, SkillVersion(1)), wording: wording, buildingBlock: .mutualReveal,
            topicsUsed: used, topicsRequired: required, permissions: permissions,
            accepts: accepts, produces: produces,
            intent: IntentSchema(slots: slots ?? [IntentSlot(.activity, required: true, hint: "what they want to do")])
        )
    }

    @Test func skillIDsUseTheIssueKeyFormat() throws {
        #expect(try SkillID("down_for") == .downFor)
        for bad in ["", "Down", "1skill", "has space", String(repeating: "a", count: 33)] {
            #expect(throws: ValidationError.self) { try SkillID(bad) }
        }
    }

    @Test func versionsParseAndCompareByMajor() throws {
        #expect(try SkillVersion("1.2") == SkillVersion(1, 2))
        #expect(SkillVersion(1, 0).isCompatible(with: SkillVersion(1, 9)))
        #expect(!SkillVersion(1, 0).isCompatible(with: SkillVersion(2, 0)))
        #expect(SkillVersion(1, 2) < SkillVersion(2, 0))
        for bad in ["1", "1.", ".1", "1.2.3", "a.b", "-1.0", "99999999.0", "1.٣"] {
            #expect(throws: ValidationError.self) { try SkillVersion(bad) }
        }
        let ref = SkillRef(.findATime, SkillVersion(1, 3))
        let json = try JSONEncoder().encode(ref)
        #expect(String(decoding: json, as: UTF8.self).contains(#""1.3""#))
        #expect(try JSONDecoder().decode(SkillRef.self, from: json) == ref)
    }

    @Test func requiredTopicsMustBeUsedAndCoverTheSlots() throws {
        #expect(throws: ValidationError.self) { try Self.descriptor(used: [.activity], required: [.time]) }
        // A slot for budget needs the budget topic.
        #expect(throws: ValidationError.self) {
            try Self.descriptor(slots: [IntentSlot(.budget, required: false, hint: "how much")])
        }
        #expect(throws: ValidationError.self) { try IntentSchema(slots: []) }
        let slot = try IntentSlot(.activity, required: true, hint: "x")
        #expect(throws: ValidationError.self) { try IntentSchema(slots: [slot, slot]) }
    }

    @Test func aRequiredTopicSetToNeverBlocksTheSkill() throws {
        let pickAPlace = try Self.descriptor(.pickAPlace, used: [.place, .budget, .diet], required: [.place],
                                             slots: [IntentSlot(.place, required: false, hint: "where")])
        var settings = PrivacySettings.defaults
        #expect(pickAPlace.blockingTopics(in: settings).isEmpty)
        try settings.set(.never, for: .budget)
        #expect(pickAPlace.blockingTopics(in: settings).isEmpty)
        try settings.set(.never, for: .place)
        #expect(pickAPlace.blockingTopics(in: settings) == [.place])
    }

    /// ADR 0020: only a mutual reveal skill can ask quietly.
    @Test func sendModesAreDeclaredAndAskQuietlyNeedsMutualReveal() throws {
        func make(_ block: BuildingBlock, _ modes: [SendMode]) throws -> SkillDescriptor {
            try SkillDescriptor(ref: SkillRef(.downFor, SkillVersion(1)), wording: Self.wording, buildingBlock: block,
                                topicsUsed: [.time, .activity], topicsRequired: [.time, .activity], produces: [.plan],
                                intent: IntentSchema(slots: [IntentSlot(.activity, required: true, hint: "what")]), sendModes: modes)
        }
        #expect(try make(.mutualReveal, [.askQuietly, .invite]).defaultSendMode == .askQuietly)
        #expect(try make(.privateQuery, [.invite]).sendModes == [.invite])
        #expect(throws: ValidationError.self) { try make(.privateQuery, [.askQuietly, .invite]) }
        #expect(throws: ValidationError.self) { try make(.mutualReveal, []) }
        #expect(throws: ValidationError.self) { try make(.mutualReveal, [.invite, .invite]) }
        // Every sample skill but Down for only invites.
        for skill in SampleSkills.all {
            #expect(skill.sendModes == (skill.id == .downFor ? [.askQuietly, .invite] : [.invite]))
        }
        #expect(try JSONEncoder().encode(SendMode.askQuietly) == Data(#""ask_quietly""#.utf8))
    }

    @Test func chainsFollowArtifactsAndExposeOnlyWhatIsNew() throws {
        let down = try Self.descriptor(produces: [.plan])
        let place = try Self.descriptor(.pickAPlace, used: [.place, .budget], required: [.place], permissions: [.locationWhenInUse],
                                        accepts: [.plan], produces: [.placeChoice],
                                        slots: [IntentSlot(.place, required: false, hint: "where")])
        #expect(place.canFollow(down))
        #expect(!down.canFollow(place))
        let added = place.exposure.adding(over: down.exposure)
        #expect(added.topics == [.budget])
        #expect(added.permissions == [.locationWhenInUse])
        #expect(down.exposure.adding(over: down.exposure.union(place.exposure)).isEmpty)
    }
}
