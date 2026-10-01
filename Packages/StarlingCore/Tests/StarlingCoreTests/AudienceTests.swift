import Foundation
import StarlingCore
import Testing

/// ADR 0020 decisions 6 to 8.
@Suite struct AudienceTests {
    static func peer(_ byte: UInt8) -> PeerID { try! PeerID(bytes: Data(repeating: byte, count: 32)) }
    static let maya = peer(10), jake = peer(11), priya = peer(12), sam = peer(13)
    static let friends = [maya, jake, priya, sam]
    static func everyone(_: PeerID) -> Bool { true }

    @Test func everyoneExceptLeavesOutExactlyThoseFriends() {
        let audience = Audience.everyoneExcept([Self.jake])
        #expect(audience.resolve(mode: .askQuietly, friends: Self.friends, book: .empty, canRun: Self.everyone) == [Self.maya, Self.priya, Self.sam])
    }

    @Test func aSavedGroupIsItsMembersAndAnUnknownGroupIsNobody() throws {
        let climbing = try FriendGroup(name: " Climbing ", members: [Self.priya, Self.maya])
        #expect(climbing.name == "Climbing")
        let book = AudienceBook(groups: [climbing], rules: [Self.sam: .alwaysInclude])
        #expect(Audience.group(climbing.id).resolve(mode: .invite, friends: Self.friends, book: book, canRun: Self.everyone) == [Self.maya, Self.priya, Self.sam])
        #expect(Audience.group(GroupID()).resolve(mode: .invite, friends: Self.friends, book: book, canRun: Self.everyone).isEmpty)
    }

    @Test func standingRulesShapeBroadAudiencesButNotAnExplicitPick() {
        let book = AudienceBook(closeFriends: [Self.maya], rules: [Self.jake: .neverInclude, Self.priya: .quietOnly, Self.sam: .alwaysInclude])
        #expect(Audience.allFriends.resolve(mode: .askQuietly, friends: Self.friends, book: book, canRun: Self.everyone) == [Self.maya, Self.priya, Self.sam])
        #expect(Audience.allFriends.resolve(mode: .invite, friends: Self.friends, book: book, canRun: Self.everyone) == [Self.maya, Self.sam])
        #expect(Audience.closeFriends.resolve(mode: .invite, friends: Self.friends, book: book, canRun: Self.everyone) == [Self.maya, Self.sam])
        // Excepting a friend beats always include.
        #expect(Audience.everyoneExcept([Self.sam]).resolve(mode: .askQuietly, friends: Self.friends, book: book, canRun: Self.everyone) == [Self.maya, Self.priya])
        // Picking now beats every standing rule.
        #expect(Audience.picked([Self.jake, Self.priya]).resolve(mode: .invite, friends: Self.friends, book: book, canRun: Self.everyone) == [Self.jake, Self.priya])
    }

    @Test func onlyPairedFriendsWhoseCardsSupportTheSkillStay() {
        let stranger = Self.peer(99)
        let book = AudienceBook(rules: [stranger: .alwaysInclude])
        let resolved = Audience.picked([stranger, Self.maya, Self.jake]).resolve(mode: .invite, friends: Self.friends, book: book, canRun: { $0 != Self.jake })
        #expect(resolved == [Self.maya])
        #expect(!Audience.allFriends.resolve(mode: .invite, friends: Self.friends, book: book, canRun: Self.everyone).contains(stranger))
    }

    @Test func groupNamesAreBoundedTextAndRoundTrip() throws {
        for bad in ["", "   ", String(repeating: "a", count: 33), "two\nlines", "tab\u{7}"] {
            #expect(throws: ValidationError.self) { try FriendGroup(name: bad, members: []) }
        }
        let book = AudienceBook(closeFriends: [Self.maya], groups: [try FriendGroup(name: "Work", members: [Self.sam])], rules: [Self.jake: .quietOnly])
        #expect(try JSONDecoder().decode(AudienceBook.self, from: JSONEncoder().encode(book)) == book)
        let forged = Data(#"{"id":"00000000-0000-4000-8000-000000000001","name":"","members":[]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FriendGroup.self, from: forged) }
    }
}
