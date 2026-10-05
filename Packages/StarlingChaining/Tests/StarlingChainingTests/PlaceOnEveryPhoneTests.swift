import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

/// A place agreed for a plan reaches every phone's stored plan, the
/// organizer's and each friend's, at the same revision (review of PR #118).
/// Each phone plays lane A's coordinator: it applies every event Pick a
/// place emits, in the order its service emits them (PR #118), and after
/// each one saves `ChainPlanner.parent(updatedBy:in:)` when there is one.
@Suite struct PlaceOnEveryPhoneTests {
    /// One phone's store and coordinator.
    struct Phone {
        let me: PeerID
        var interactions: [Interaction]
        var planner: ChainPlanner { ChainPlanner(registry: try! SkillRegistry(SampleSkills.all), me: me) }

        var root: Interaction { interactions[0] }
        var plan: Plan? { interactions[0].plan }

        /// Applies one of a link's events, then lets the result update the plan.
        mutating func apply(_ event: SkillEvent, to linkID: InteractionID, at minute: Int) throws {
            let index = try #require(interactions.firstIndex { $0.id == linkID })
            switch event {
            case .lifecycle(_, let lifecycle): try interactions[index].apply(lifecycle, at: Fixtures.at(minutes: minute))
            case .produced(_, let artifact): interactions[index].record(artifact)
            case .incoming: break
            }
            if let updated = planner.parent(updatedBy: interactions[index], in: interactions) {
                let parent = try #require(interactions.firstIndex { $0.id == updated.id })
                interactions[parent] = updated
            }
        }
    }

    /// The plan agreed in `origin` by you, Maya, and Jake, as each phone holds it.
    static func phones() throws -> (you: Phone, maya: Phone) {
        let root = try Fixtures.plannedDownFor()
        let plan = try #require(root.plan)
        var theirs = Interaction(conversation: root.conversation, skill: SampleSkills.downFor.ref, role: .invitee,
                                 participants: [Fixtures.me, Fixtures.jake], createdAt: Fixtures.at(minutes: 0))
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        try theirs.apply(.proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: terms, plan: plan)), at: Fixtures.at(minutes: 2))
        try theirs.apply(.ownerAccepted(revision: 1), at: Fixtures.at(minutes: 3))
        try theirs.apply(.everyoneConfirmed(revision: 1), at: Fixtures.at(minutes: 4))
        theirs.record(.plan(plan))
        return (Phone(me: Fixtures.me, interactions: [root]), Phone(me: Fixtures.maya, interactions: [theirs]))
    }

    /// `organizer`'s own place link for its plan, and the same step as a
    /// friend's request on `friend`'s phone, grouped by its hint.
    static func link(organizedBy organizer: inout Phone, reaching friend: inout Phone, at minute: Int) throws -> (own: InteractionID, theirs: InteractionID) {
        let parent = organizer.root
        let own = Interaction(
            skill: SampleSkills.pickAPlace.ref, role: .initiator, participants: [Fixtures.me, Fixtures.maya, Fixtures.jake].filter { $0 != organizer.me },
            createdAt: Fixtures.at(minutes: minute),
            chain: ChainLink(parent: parent.id, parentConversation: parent.conversation, consumed: [.plan], trigger: .atConfirm,
                             optedInAt: Fixtures.at(minutes: minute))
        )
        var theirs = Interaction(skill: SampleSkills.pickAPlace.ref, role: .invitee, participants: [organizer.me], createdAt: Fixtures.at(minutes: minute))
        try theirs.setFriendChainHint(parent.planConversation)
        organizer.interactions.append(own)
        friend.interactions.append(theirs)
        return (own.id, theirs.id)
    }

    /// What Pick a place emits on every phone once everyone agreed `place`
    /// over `basis` with `roster`: the agreed plan names the next revision.
    static func agreed(_ place: PlaceChoice, over basis: Plan, roster: [PeerID], organizer: Bool) throws -> [SkillEvent] {
        let id = InteractionID()
        let plan = try basis.updating(attendees: Attendees(basis.attendees.peers.filter(roster.contains)), place: .some(place))
        let proposal = SkillProposal(revision: 1, participants: roster, terms: try Terms([.place: .places([place])]), plan: plan)
        let lifecycle: [InteractionEvent] = (organizer ? [.started] : []) + [.proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)]
        return lifecycle.map { SkillEvent.lifecycle(id, $0) }
            + [.produced(id, .placeChoice(place)), .produced(id, .attendees(try Attendees(roster)))]
    }

    @Test func aFriendsPhoneStoresTheAgreedPlaceAndCanChangeItNext() throws {
        var (you, maya) = try Self.phones()
        let everyone = [Fixtures.me, Fixtures.maya, Fixtures.jake]
        // You pick a place for the plan; Maya and Jake agree.
        let first = try Self.link(organizedBy: &you, reaching: &maya, at: 10)
        let place = Fixtures.place("Boba Guys on Franklin")
        let basis = try #require(you.plan)
        for (minute, event) in try Self.agreed(place, over: basis, roster: everyone, organizer: true).enumerated() {
            try you.apply(event, to: first.own, at: 11 + minute)
        }
        for (minute, event) in try Self.agreed(place, over: basis, roster: everyone, organizer: false).enumerated() {
            try maya.apply(event, to: first.theirs, at: 11 + minute)
        }
        for phone in [you, maya] {
            #expect(phone.plan?.place == place)
            #expect(phone.plan?.revision == 1)
            #expect(phone.plan?.attendees.peers == everyone)
        }

        // Maya taps "Somewhere else?" on her stored plan: a change of the
        // place at revision 1, which your phone takes as her request.
        let second = try Self.link(organizedBy: &maya, reaching: &you, at: 30)
        let next = Fixtures.place("Plentea")
        let moved = try #require(maya.plan)
        for (minute, event) in try Self.agreed(next, over: moved, roster: everyone, organizer: true).enumerated() {
            try maya.apply(event, to: second.own, at: 31 + minute)
        }
        for (minute, event) in try Self.agreed(next, over: moved, roster: everyone, organizer: false).enumerated() {
            try you.apply(event, to: second.theirs, at: 31 + minute)
        }
        for phone in [you, maya] {
            #expect(phone.plan?.place == next)
            #expect(phone.plan?.revision == 2)
            #expect(phone.plan?.attendees.peers == everyone)
            #expect(phone.plan?.id == basis.id)
        }
    }

    /// The review of #118 and finding 5: a first place agreed over revision
    /// 0, narrowed to those who accepted, finishes after another step placed
    /// the plan. It neither overwrites the place nor narrows the plan.
    @Test func aFirstPlaceThatFinishesLateChangesNothing() throws {
        var (you, maya) = try Self.phones()
        let everyone = [Fixtures.me, Fixtures.maya, Fixtures.jake]
        let basis = try #require(you.plan)
        let yours = try Self.link(organizedBy: &you, reaching: &maya, at: 10)
        let hers = try Self.link(organizedBy: &maya, reaching: &you, at: 10)
        // Maya's step finishes first: everyone agreed.
        let theirs = Fixtures.place("Plentea")
        for (minute, event) in try Self.agreed(theirs, over: basis, roster: everyone, organizer: true).enumerated() {
            try maya.apply(event, to: hers.own, at: 11 + minute)
        }
        for (minute, event) in try Self.agreed(theirs, over: basis, roster: everyone, organizer: false).enumerated() {
            try you.apply(event, to: hers.theirs, at: 11 + minute)
        }
        // Yours finishes after, over revision 0, without Jake.
        let late = Fixtures.place("Boba Guys on Franklin")
        for (minute, event) in try Self.agreed(late, over: basis, roster: [Fixtures.me, Fixtures.maya], organizer: true).enumerated() {
            try you.apply(event, to: yours.own, at: 21 + minute)
        }
        for (minute, event) in try Self.agreed(late, over: basis, roster: [Fixtures.me, Fixtures.maya], organizer: false).enumerated() {
            try maya.apply(event, to: yours.theirs, at: 21 + minute)
        }
        for phone in [you, maya] {
            #expect(phone.plan?.place == theirs)
            #expect(phone.plan?.revision == 1)
            #expect(phone.plan?.attendees.peers == everyone)
        }
    }
}
