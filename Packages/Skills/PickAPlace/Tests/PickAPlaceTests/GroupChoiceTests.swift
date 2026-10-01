import PickAPlace
import StarlingCore
import Testing

@Suite("Group choice")
struct GroupChoiceTests {
    let maya = PeerID.random()
    let jake = PeerID.random()
    let priya = PeerID.random()
    let a = place("Boba Guys"), b = place("Tea Lab"), c = place("Pho Hoa")

    @Test func picksThePlaceThatFitsEveryone() {
        let choice = GroupChoice.choose(organizer: [a, b, c], answers: [maya: [b, c], jake: [c, b]])
        // b and c fit both; b ranks 1+0+1 = 2, c ranks 2+1+0 = 3.
        #expect(choice == GroupChoice(place: b, friends: [maya, jake].sorted()))
    }

    @Test func prefersMoreFriendsOverBetterRank() {
        let choice = GroupChoice.choose(organizer: [a, b], answers: [maya: [a], jake: [b], priya: [b]])
        #expect(choice?.place == b)
        #expect(choice?.friends == [jake, priya].sorted())
    }

    @Test func tiesKeepTheOrganizersOrder() {
        let choice = GroupChoice.choose(organizer: [a, b], answers: [maya: [b, a]])
        #expect(choice?.place == a)
    }

    @Test func ignoresPlacesTheOrganizerNeverOffered() {
        let stranger = place("Not Asked")
        #expect(GroupChoice.choose(organizer: [a], answers: [maya: [stranger]]) == nil)
    }

    @Test func nilWhenNoPlaceFitsAnyFriend() {
        #expect(GroupChoice.choose(organizer: [a, b], answers: [maya: [], jake: [c]]) == nil)
        #expect(GroupChoice.choose(organizer: [a], answers: [:]) == nil)
    }
}
