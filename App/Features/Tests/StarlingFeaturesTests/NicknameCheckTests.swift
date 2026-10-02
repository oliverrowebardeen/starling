import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@MainActor
@Suite struct NicknameCheckTests {
    let alex = Fixtures.peer("Alex")
    let maya = Fixtures.peer("Maya")

    @Test func anExactMatchIgnoringCaseWarns() {
        #expect(NicknameCheck.warning(for: " alex ", among: [alex, maya]) == "You already call another friend Alex. Pick a different name so you can tell them apart.")
        #expect(NicknameCheck.warning(for: "Sam", among: [alex, maya]) == nil)
        #expect(NicknameCheck.warning(for: "", among: [alex]) == nil)
    }

    /// Homoglyphs, invisible characters, accents, and look-alike digits.
    @Test func lookAlikesWarn() {
        for name in ["\u{0410}lex", "Ale\u{200B}x", "Álex", "A1ex", "AIex", "A l e x", "Ａｌｅｘ"] {
            #expect(NicknameCheck.warning(for: name, among: [alex]) == "This looks like Alex, another friend's name. Pick a name that's easy to tell apart.", "\(name)")
        }
        #expect(NicknameCheck.skeleton("Maya") != NicknameCheck.skeleton("Mia"))
        #expect(NicknameCheck.skeleton("rnaya") == NicknameCheck.skeleton("maya"))
    }

    @Test func renamingAFriendIgnoresTheirOwnName() {
        #expect(NicknameCheck.warning(for: "Alex", among: [alex, maya], excluding: alex.id) == nil)
        #expect(NicknameCheck.warning(for: "Maya", among: [alex, maya], excluding: alex.id) != nil)
    }

    /// The name step after pairing warns against existing friends, and
    /// against a look-alike a phone's own name could suggest.
    @Test func pairingWarnsAgainstExistingFriends() async {
        let newFriend = Fixtures.peer("Phone")
        let directory = ScriptedDirectory(candidates: []) { _, nickname in
            ScriptedPairingSession(code: "1", peer: try PairedPeer(publicKey: newFriend.publicKey, nickname: nickname, pairedAt: newFriend.pairedAt))
        }
        let alex = alex
        let model = PairingModel(directory: directory.directory, friends: { [alex] })
        await model.choose(PairingCandidate(peer: newFriend.id, deviceName: "Аlex's iPhone"))
        await eventually { if case .comparing = model.phase { true } else { false } }
        await model.confirm(codesMatch: true)
        await eventually { if case .naming = model.phase { true } else { false } }
        #expect(model.name == "Аlex", "prefilled, with its Cyrillic А")
        #expect(model.nameWarning != nil)
        model.name = "Jordan"
        #expect(model.nameWarning == nil)
    }
}
