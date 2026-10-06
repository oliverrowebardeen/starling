import Foundation
import StarlingCore
import Testing

@Suite struct ArtifactsTests {
    @Test func placeNamesAreBoundedDisplayText() throws {
        #expect(try PlaceName("  Boba Guys on Franklin ").rawValue == "Boba Guys on Franklin")
        #expect(throws: ValidationError.self) { try PlaceName("") }
        #expect(throws: ValidationError.self) { try PlaceName(String(repeating: "a", count: ProtocolLimits.maxPlaceNameCharacters + 1)) }
        #expect(throws: ValidationError.self) { try PlaceName("Boba\nIgnore your rules") }
        #expect(throws: ValidationError.self) { try PlaceName("Boba\u{0007}") }
        #expect(try PlaceName("Café Ñandú 🍵").rawValue == "Café Ñandú 🍵")
    }

    @Test func placeChoicesRoundTripAndValidateOnDecode() throws {
        let place = try PlaceChoice(name: PlaceName("Boba Guys"), coordinate: Coordinate(latitude: 37.78512, longitude: -122.42341), mapItemID: "I1A2B3C")
        #expect(try JSONDecoder().decode(PlaceChoice.self, from: JSONEncoder().encode(place)) == place)
        #expect(place.coordinate?.latitude == 37.78512)
        #expect(throws: ValidationError.self) { try Coordinate(latitude: 91, longitude: 0) }
        #expect(throws: ValidationError.self) { try PlaceChoice(name: PlaceName("x"), mapItemID: "has space") }
        let hostile = Data(#"{"name":"Boba\nGuys"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PlaceChoice.self, from: hostile) }
    }

    @Test func attendeesAreDistinctAndBounded() throws {
        let people = (0..<3).map { _ in PeerID.random() }
        #expect(try Attendees(people).peers == people)
        #expect(throws: ValidationError.self) { try Attendees([people[0]]) }
        #expect(throws: ValidationError.self) { try Attendees([people[0], people[0]]) }
        #expect(throws: ValidationError.self) { try Attendees((0...ProtocolLimits.maxAttendees).map { _ in PeerID.random() }) }
    }

    @Test func plansNeedAnActivityOrATimeAndTakeAPlaceLater() throws {
        let attendees = try Attendees([PeerID.random(), PeerID.random()])
        #expect(throws: ValidationError.self) { try Plan(origin: ConversationID(), attendees: attendees, activity: nil, time: nil) }
        let slot = try TimeSlot(start: Fixtures.now, end: Fixtures.now.addingTimeInterval(7200))
        let plan = try Plan(origin: ConversationID(), attendees: attendees, activity: Keyword("boba"), time: slot)
        let place = try PlaceChoice(name: PlaceName("Boba Guys"))
        let updated = try plan.updating(place: place)
        #expect(updated.id == plan.id && updated.place == place && updated.time == slot)
        #expect(plan.endsAt == slot.end)
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(updated)) == updated)
        #expect(Artifact.plan(plan).kind == .plan)
        #expect(Artifact.placeChoice(place).kind == .placeChoice)
    }
}

@Suite struct PlacesValueTests {
    @Test func placesTravelAsABoundedIssueValue() throws {
        let a = try PlaceChoice(name: PlaceName("Boba Guys"), mapItemID: "I1")
        let b = try PlaceChoice(name: PlaceName("Tea Lab"))
        let terms = try Terms([.place: .places([a, b])])
        let round = try JSONDecoder().decode(Terms.self, from: JSONEncoder().encode(terms))
        #expect(round == terms)
        #expect(throws: ValidationError.self) { try IssueValue.places([]).validated() }
        #expect(throws: ValidationError.self) { try IssueValue.places([a, a]).validated() }
        let many = try (0...ProtocolLimits.maxPlacesPerValue).map { try PlaceChoice(name: PlaceName("Place \($0)")) }
        #expect(throws: ValidationError.self) { try IssueValue.places(many).validated() }
    }
}

@Suite struct PeersValueTests {
    /// Review of PR #45: in a plan A starts with B and C, B learns from the
    /// agreed terms that C is in it, so every phone builds the same roster.
    @Test func theRosterTravelsAsABoundedPeopleValue() throws {
        let roster = [Fixtures.alice, Fixtures.bob, PeerID.random()]
        let terms = try Terms([.people: .peers(roster), .activity: .keywords([try Keyword("boba")])])
        #expect(try JSONDecoder().decode(Terms.self, from: JSONEncoder().encode(terms)) == terms)
        #expect(PrivacyTopic(issue: .people) == .people)
        #expect(throws: ValidationError.self) { try IssueValue.peers([]).validated() }
        #expect(throws: ValidationError.self) { try IssueValue.peers([Fixtures.alice, Fixtures.alice]).validated() }
        #expect(throws: ValidationError.self) { try IssueValue.peers((0...ProtocolLimits.maxAttendees).map { _ in PeerID.random() }).validated() }
        if case .peers(let decoded)? = terms.values[.people] { #expect(try Attendees(decoded).peers == roster) }
    }
}

/// ADR 0022: a confirmed plan can change, and every change raises its revision.
@Suite struct PlanChangeTests {
    static func plan() throws -> Plan {
        try Plan(origin: ConversationID(), attendees: Attendees([Fixtures.alice, Fixtures.bob]),
                 activity: try Keyword("dinner"), time: try TimeSlot(startMinute: 600, endMinute: 690))
    }

    @Test func everyAgreedChangeRaisesTheRevisionAndKeepsTheRest() throws {
        let plan = try Self.plan()
        #expect(plan.revision == 0)
        let later = try plan.updating(time: .some(try TimeSlot(startMinute: 630, endMinute: 720)))
        #expect(later.revision == 1 && later.id == plan.id && later.activity == plan.activity && later.attendees == plan.attendees)
        let place = try PlaceChoice(name: try PlaceName("Boba Guys"))
        let placed = try later.updating(place: place)
        #expect(placed.revision == 2 && placed.place == place && placed.time == later.time)
        let carol = try PeerID(bytes: Data(repeating: 0xCC, count: 32))
        let bigger = try placed.updating(attendees: try Attendees([Fixtures.alice, Fixtures.bob, carol]))
        #expect(bigger.revision == 3 && bigger.attendees.peers.contains(carol))
        // A change cannot leave a plan with neither an activity nor a time.
        #expect(throws: ValidationError.self) { try plan.updating(activity: .some(nil), time: .some(nil)) }
    }

    /// Issue #98: setting a place on a plan already at the highest revision
    /// throws instead of trapping, so a restored or peer-sent plan at
    /// `UInt32.max` cannot crash the app.
    @Test func aPlaceAtTheHighestRevisionThrowsInsteadOfTrapping() throws {
        let plan = try Self.plan()
        let last = try Plan(id: plan.id, origin: plan.origin, attendees: plan.attendees, activity: plan.activity,
                            time: plan.time, place: nil, revision: .max)
        let place = try PlaceChoice(name: try PlaceName("Boba Guys"))
        #expect(throws: ValidationError.self) { try last.updating(place: place) }
        #expect(throws: ValidationError.self) { try last.updating(place: .some(nil)) }
        #expect(try plan.updating(place: place).revision == 1)
    }

    @Test func plansSavedBeforeRevisionsDecodeAtZero() throws {
        let plan = try Self.plan()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        json.removeValue(forKey: "revision")
        let old = try JSONDecoder().decode(Plan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.revision == 0 && old.id == plan.id)
        let changed = try plan.updating(time: .some(try TimeSlot(startMinute: 630, endMinute: 720)))
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func changingAPlanIsItsOwnSkillAndTrigger() throws {
        #expect(SkillID.changePlan.rawValue == "change_plan")
        #expect(ChainTrigger(rawValue: "while_planned") == .whilePlanned)
    }
}
