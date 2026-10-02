@testable import FindATime
import Foundation
import StarlingCore
import StarlingFakes
import Testing

struct SkillTests {
    @Test func descriptorMatchesTheSample() {
        let sample = SampleSkills.findATime
        let real = FindATimeSkill.descriptor
        #expect(real.ref == sample.ref)
        #expect(real.wording == sample.wording)
        #expect(real.buildingBlock == .privateQuery)
        // The same slots, but no expiry chip (device test, 2026-10-02).
        #expect(real.intent.slots == sample.intent.slots)
        #expect(real.intent.asksForAudience)
        #expect(!real.intent.asksForExpiry)
        #expect(real.permissions == [.calendarFullAccess])
        #expect(real.produces == [.timeSlot, .plan])
        #expect(real.topicsRequired == [.time])
        #expect(real.topicsUsed == sample.topicsUsed)
        #expect(real.topicsUsed.contains(.calendarDetails))
        #expect(real.sendModes == [.invite])
        #expect(real.defaultSendMode == .invite)
    }

    @Test func registersWithTheOtherSkillsAndRuns() throws {
        let registry = try SkillRegistry([SampleSkills.downFor, FindATimeSkill.descriptor, SampleSkills.pickAPlace, SampleSkills.swapPhotos])
        let settings = SkillSettings(flags: .phase1_5)
        #expect(registry.availability(of: .findATime, in: settings) == .available)
        #expect(registry.advertised(in: settings).contains(FindATimeSkill.ref))
        // Pick a place can follow it: it accepts a plan or a time.
        #expect(registry.chainSuggestions(after: .findATime, in: settings, peers: []).map(\.id).contains(.pickAPlace))
        // The people topic set to Never does not block it: only time is required.
        var privacy = PrivacySettings()
        try privacy.set(.never, for: .people)
        #expect(FindATimeSkill.descriptor.blockingTopics(in: privacy).isEmpty)
    }

    @Test func templateSentences() throws {
        let thursday4pm = T.slot(24 * 3 + 16, 24 * 3 + 17)
        let pair = ProposalFacts(skill: FindATimeSkill.ref, friendNames: ["Priya"], activity: try Keyword("stats"), time: thursday4pm, place: nil, timeZone: T.utc)
        #expect(FindATimeTemplate.sentence(pair) == "You and Priya are free Thursday, October 8 at 4:00\u{202F}PM for stats.")
        let group = ProposalFacts(skill: FindATimeSkill.ref, friendNames: ["Maya", "Jake"], activity: nil, time: thursday4pm, place: nil, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(FindATimeTemplate.sentence(group) == "You, Maya and Jake are free Thursday, October 8 at 9:00\u{202F}AM.")
    }

    @Test func writerUsesTheModelAndFallsBackToTheTemplate() async throws {
        let me = PeerID.random()
        let priya = PeerID.random()
        let plan = try Plan(origin: ConversationID(), attendees: Attendees([me, priya]), activity: Keyword("stats"), time: T.slot(16, 17))
        let proposal = SkillProposal(revision: 1, participants: [me, priya], terms: try Terms([.time: .slots([T.slot(16, 17)])]), plan: plan)
        let names: @Sendable (PeerID) async -> String? = { $0 == priya ? "Priya" : nil }

        let model = ScriptedSkillModel(onProposal: { facts in
            #expect(facts.friendNames == ["Priya"])
            #expect(facts.place == nil)
            return "  Stats with Priya Monday at 4?  "
        })
        let writer = FindATimeProposalWriter(model: model, localPeer: me, timeZone: T.utc, nickname: names)
        #expect(await writer.sentence(for: proposal) == "Stats with Priya Monday at 4?")

        for broken in [ScriptedSkillModel(), ScriptedSkillModel(onProposal: { _ in "   " })] {
            let fallback = FindATimeProposalWriter(model: broken, localPeer: me, timeZone: T.utc, nickname: names)
            #expect(await fallback.sentence(for: proposal) == "You and Priya are free Monday, October 5 at 4:00\u{202F}PM for stats.")
        }
        let unnamed = FindATimeProposalWriter(model: nil, localPeer: me, timeZone: T.utc, nickname: { _ in nil })
        #expect(await unnamed.sentence(for: proposal).hasPrefix("You and a friend are free"))
    }

    @Test func copyHasNoEmDashes() {
        let copy = [
            FindATimeCopy.PermissionSheet.title, FindATimeCopy.PermissionSheet.body, FindATimeCopy.PermissionSheet.readsValue,
            FindATimeCopy.PermissionSheet.staysValue, FindATimeCopy.PermissionSheet.seesValueWhenAsking,
            FindATimeCopy.PermissionSheet.seesValueWhenAnswering, FindATimeCopy.PermissionSheet.footnote,
            FindATimeCopy.deniedFallback, FindATimeCopy.askOwnTimes, FindATimeCopy.askedBy("Priya"), FindATimeCopy.answerNote,
        ]
        #expect(copy.allSatisfy { !$0.contains("\u{2014}") })
        #expect(FindATimeCopy.PermissionSheet.seesLabel(friend: "Priya") == "Priya sees")
        #expect(FindATimeCopy.PermissionSheet.continueButton == "Continue")
    }
}
