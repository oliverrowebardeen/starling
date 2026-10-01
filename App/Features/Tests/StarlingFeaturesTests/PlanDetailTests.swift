import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@MainActor
@Suite struct PlanDetailTests {
    let me = PeerID.random()
    let maya = PeerID.random()
    let jake = PeerID.random()
    let at = Timestamp(Fixtures.noon)

    var words: InteractionWords {
        let names = [maya: "Maya", jake: "Jake"]
        return InteractionWords(
            registry: SampleSkills.registry, localPeer: me,
            formatter: ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: { Fixtures.noon }),
            names: { names }, now: { Fixtures.noon }
        )
    }

    var slot: TimeSlot { get throws { try TimeSlot(start: Fixtures.noon.addingTimeInterval(6 * 3600), end: Fixtures.noon.addingTimeInterval(8 * 3600)) } }

    func planned(_ skill: SkillDescriptor, chain: ChainLink? = nil, at offset: Int64 = 0, artifacts: [Artifact]) throws -> Interaction {
        let time = Timestamp(millisecondsSince1970: at.millisecondsSince1970 + offset)
        var item = Interaction(skill: skill.ref, role: .initiator, participants: [maya, jake], createdAt: time, chain: chain)
        let proposal = SkillProposal(revision: 1, participants: [me, maya, jake], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try item.apply(event, at: time)
        }
        for artifact in artifacts { item.record(artifact) }
        return item
    }

    func bobaPlan(origin: ConversationID) throws -> Plan {
        try Plan(origin: origin, attendees: Attendees([me, maya, jake]), activity: Keyword("boba"), time: slot)
    }

    @Test func aChainedPlaceMovesThePlanAndTheTimelineTellsTheStory() throws {
        var root = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya, jake], createdAt: at)
        root = try planned(SampleSkills.downFor, artifacts: [])
        root.record(.plan(try bobaPlan(origin: root.conversation)))
        root.record(EgressRecord(at: at, recipient: maya, items: [
            DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")])),
            DisclosedItem(category: .psi, issue: .time, value: .slots([try slot])),
        ]))
        let place = try PlaceChoice(name: PlaceName("Boba Guys"), coordinate: Coordinate(latitude: 37.77, longitude: -122.42))
        let link = ChainLink(parent: root.id, parentConversation: root.conversation, consumed: [.plan], trigger: .atConfirm, optedInAt: at)
        var pick = try planned(SampleSkills.pickAPlace, chain: link, at: 60_000, artifacts: [.placeChoice(place)])
        pick.record(EgressRecord(at: at, recipient: maya, items: [DisclosedItem(category: .terms, issue: .place, value: .places([place]))]))
        let unrelated = try planned(SampleSkills.downFor, at: 120_000, artifacts: [])

        let notes = PlanNotes(file: nil, now: { Fixtures.noon.addingTimeInterval(180) })
        notes.record(.calendar, for: root.id)
        let detail = PlanDetail(root: root, all: [unrelated, pick, root], words: words, notes: notes)

        #expect(detail.chain.map(\.id) == [root.id, pick.id])
        #expect(detail.plan?.place == place)
        #expect(detail.title == "Boba with Maya and Jake")
        #expect(plain(detail.subtitle) == "Tonight at 8:13 PM · Boba Guys")
        #expect(detail.people == "You, Maya and Jake")
        #expect(detail.saidYes == "All 3 of you said yes")
        #expect(detail.timeline.map(\.tag) == ["Down for…", "Pick a place", "Calendar"])
        #expect(detail.timeline.map(\.text) == ["All 3 down for boba", "Boba Guys · 3 of 3 agreed", "Added to your calendar"])
        #expect(!detail.timeline.contains { !$0.isDone })

        // What left the phone equals the egress log; location, budget, and
        // diet never did.
        #expect(detail.shared.map(plain) == ["Tonight 8:13 PM to 10:14 PM", "Boba", "Boba Guys"], "in topic order")
        #expect(detail.kept == ["Exact location", "Budget", "Diet"])
        #expect(detail.auditIsComplete)
    }

    /// Core v2.1: a send whose items the policy could not state means
    /// nothing can be said to have stayed on the phone.
    @Test func anUnknownSendClaimsNothingStayed() throws {
        var root = try planned(SampleSkills.downFor, artifacts: [])
        root.record(EgressRecord(at: at, recipient: maya, items: [], message: MessageID(), itemsUnknown: true))
        let detail = PlanDetail(root: root, all: [root], words: words, notes: PlanNotes(file: nil))
        #expect(detail.kept.isEmpty)
        #expect(!detail.auditIsComplete)
    }

    /// P15-E request 4.1: a conversation the egress recorder cannot yet
    /// confirm, or an unreadable journal, means nothing is claimed kept.
    @Test func anUnconfirmedLogOrUnreadableJournalClaimsNothingKept() throws {
        var root = try planned(SampleSkills.downFor, artifacts: [])
        root.record(.plan(try bobaPlan(origin: root.conversation)))
        let notes = PlanNotes(file: nil)
        #expect(!PlanDetail(root: root, all: [root], words: words, notes: notes).kept.isEmpty)
        let unconfirmed = PlanDetail(root: root, all: [root], words: words, notes: notes, unconfirmed: [root.conversation])
        #expect(unconfirmed.kept.isEmpty)
        #expect(!unconfirmed.auditIsComplete)
        let unreadable = PlanDetail(root: root, all: [root], words: words, notes: notes, auditUnknown: true)
        #expect(unreadable.kept.isEmpty)
        #expect(!unreadable.auditIsComplete)
    }

    @Test func handOffsArePrefilledFromThePlan() throws {
        var root = try planned(SampleSkills.downFor, artifacts: [])
        let place = try PlaceChoice(name: PlaceName("Boba Guys"))
        root.record(.plan(try bobaPlan(origin: root.conversation).updating(place: place)))
        let notes = PlanNotes(file: nil)
        notes.link(maya, to: ContactLink(contactID: "c1", name: "Maya Lin", phone: "+1 555 0100"))
        let detail = PlanDetail(root: root, all: [root], words: words, notes: notes)

        let calendar = try #require(detail.calendar)
        #expect(calendar.title == "Boba with Maya and Jake")
        let expected = try slot
        #expect(calendar.start == expected.start)
        #expect(calendar.location == "Boba Guys")
        #expect(detail.message.recipients == ["+1 555 0100"])
        #expect(detail.message.unlinked == [jake])
        #expect(plain(detail.message.body) == "It's a plan: boba, tonight at 8:13 PM, Boba Guys.")
        #expect(detail.place == place)
    }

    @Test func notesSurviveARelaunch() throws {
        let file = JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "starling-notes-\(UUID().uuidString).json"))
        let id = InteractionID()
        let first = PlanNotes(file: file)
        first.record(.messages, for: id)
        first.link(maya, to: ContactLink(contactID: "c1", name: "Maya Lin", phone: "+1 555 0100"))
        let second = PlanNotes(file: file)
        second.load()
        #expect(second.handOffs[id]?.map(\.kind) == [.messages])
        #expect(second.contactLinks[maya]?.phone == "+1 555 0100")
        second.unlink(maya)
        let third = PlanNotes(file: file)
        third.load()
        #expect(third.contactLinks.isEmpty)
    }

    @Test func theNextPlanForSiri() throws {
        #expect(NextPlanAnswer.text([], words: words, now: Fixtures.noon) == "You have no plans coming up.")
        var root = try planned(SampleSkills.downFor, artifacts: [])
        root.record(.plan(try bobaPlan(origin: root.conversation)))
        #expect(plain(NextPlanAnswer.text([root], words: words, now: Fixtures.noon)) == "Boba with Maya and Jake, tonight at 8:13 PM.")
        #expect(NextPlanAnswer.text([root], words: words, now: Fixtures.noon.addingTimeInterval(9 * 3600)) == "You have no plans coming up.")
    }
}
