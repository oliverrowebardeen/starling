import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import Testing

@Suite struct DescriptorTests {
    @Test func theDescriptorKeepsThePlanWordingAndTheSampleShape() {
        let sample = SampleSkills.downFor
        #expect(DownFor.descriptor.ref == sample.ref)
        #expect(DownFor.descriptor.wording == sample.wording)
        #expect(DownFor.descriptor.buildingBlock == .mutualReveal)
        #expect(DownFor.descriptor.intent == sample.intent)
        #expect(DownFor.descriptor.topicsRequired == [.time, .activity])
        // The roster leaves the phone once a plan forms, under people.
        #expect(DownFor.descriptor.topicsUsed.contains(.people))
        #expect(DownFor.descriptor.permissions.isEmpty)
        #expect(DownFor.descriptor.produces.contains(.plan))
        #expect(DownFor.descriptor.accepts == [.timeSlot])
    }

    @Test func itRegistersAndShipsInPhaseOnePointFive() throws {
        let registry = try SkillRegistry([DownFor.descriptor, SampleSkills.findATime, SampleSkills.pickAPlace])
        #expect(registry.availability(of: .downFor, in: SkillSettings(flags: .phase1_5)) == .available)
        // Pick a place can follow it: it accepts the plan Down for... produces.
        #expect(SampleSkills.pickAPlace.canFollow(DownFor.descriptor))
    }
}

@Suite struct ProposalTemplateTests {
    let a = PeerID.random()

    func facts(_ names: [String], activity: String? = "boba", at hour: Double? = 20.5, place: String? = nil) -> ProposalFacts {
        ProposalFacts(
            skill: DownFor.ref, friendNames: names, activity: activity.map(T.keyword),
            time: hour.map { T.slot($0, $0 + 1) }, place: place.map { try! PlaceName($0) }, timeZone: T.utc
        )
    }

    @Test func readsAsAPlanWithFriends() {
        #expect(ProposalTemplate.sentence(facts(["Maya"]), now: T.now) == "You and Maya are both down for boba. Tonight at 8:30 PM?")
        #expect(ProposalTemplate.sentence(facts(["Maya", "Jake"]), now: T.now) == "You, Maya and Jake are all down for boba. Tonight at 8:30 PM?")
        #expect(ProposalTemplate.sentence(facts(["Maya", "Jake", "Priya"], at: 33), now: T.now) == "You, Maya, Jake and Priya are all down for boba. Tomorrow at 9 AM?")
        #expect(ProposalTemplate.sentence(facts(["Maya", "Jake"], place: "Boba Guys"), now: T.now) == "You, Maya and Jake are all down for boba. Boba Guys tonight at 8:30 PM?")
    }

    @Test func neverSaysDownWithoutAnActivity() {
        let sentence = ProposalTemplate.sentence(facts(["Maya"], activity: nil), now: T.now)
        #expect(sentence == "You and Maya are both free. Tonight at 8:30 PM?")
        #expect(!sentence.contains("down"))
    }

    @Test func farDaysUseTheWeekday() {
        // 2026-10-02 is a Friday; four days later is Tuesday.
        #expect(ProposalTemplate.when(T.at(19 + 96), now: T.now, timeZone: T.utc) == "Tuesday at 7 PM")
        #expect(ProposalTemplate.when(T.at(12), now: T.now, timeZone: T.utc) == "today at 12 PM")
    }
}
