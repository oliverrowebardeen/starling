import Foundation
import StarlingCore
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

    @Test func pairingWarnsAgainstExistingFriends() {
        let model = PairingModel(directory: PairingDirectory(localPeer: .random(), candidates: { [] }, pair: { _, _ in fatalError() }, paired: { _ in }), friends: { [self] in [alex] })
        model.nickname = "Alex"
        #expect(model.nicknameWarning != nil)
        model.nickname = "Jordan"
        #expect(model.nicknameWarning == nil)
    }
}
