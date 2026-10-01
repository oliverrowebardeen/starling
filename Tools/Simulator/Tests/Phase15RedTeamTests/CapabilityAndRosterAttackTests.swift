import Foundation
import Scenarios
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@Suite struct CapabilityAndRosterAttackTests {
    @Test func oneUnsupportedMemberHidesChainEvenWhenOtherMembersSupportIt() throws {
        let registry = SampleSkills.registry
        let settings = SkillSettings(flags: P15.allFlags)
        let good = try P15.card(SampleSkills.all.map(\.ref))
        #expect(registry.chainSuggestions(after: .downFor, in: settings, peers: [good, good]).map(\.id) == [.pickAPlace, .swapPhotos])
        for next in [SampleSkills.pickAPlace, SampleSkills.swapPhotos] {
            for version: SkillVersion? in [nil, SkillVersion(2), SkillVersion(.max)] {
                let refs = SampleSkills.all.filter { $0.id != next.id }.map(\.ref) + (version.map { [SkillRef(next.id, $0)] } ?? [])
                let incompatible = try P15.card(refs)
                #expect(incompatible.support(for: next.ref) == (version.map { .incompatible($0) } ?? .missing))
                let suggestions = registry.chainSuggestions(after: .downFor, in: settings, peers: [good, incompatible, good])
                #expect(!suggestions.contains(next))
                #expect(suggestions.count == 1)
            }
            let minor = try P15.card([SkillRef(next.id, SkillVersion(1, .max))])
            #expect(registry.chainSuggestions(after: .downFor, in: settings, peers: [good, minor]).contains(next))
        }
    }

    @Test func forgedSkillNamesAndLegacyMetadataAreRejectedOnDecode() throws {
        let envelope = try Envelope(conversation: ConversationID(), sender: P15.alice, recipient: P15.bob,
                                    sequence: 0, sentAt: P15.now, body: .propose(Proposal(round: 0, terms: P15.proposal(1).terms)),
                                    skill: SampleSkills.swapPhotos.ref, mode: .invite, chainedFrom: ConversationID())
        let codec = EnvelopeCodec()
        let object = try #require(JSONSerialization.jsonObject(with: codec.encode(envelope)) as? [String: Any])
        for name in ["Swap_Photos", "swap_photos\n", "ѕwap_photos", "request_permission", String(repeating: "a", count: 33)] {
            var changed = object
            changed["skill"] = ["id": name, "version": "1.0"]
            let bytes = try JSONSerialization.data(withJSONObject: changed)
            if name == "request_permission" {
                let decoded = try codec.decode(bytes)
                #expect(SampleSkills.registry.descriptor(for: try #require(decoded.skill).id) == nil)
            } else {
                #expect(throws: CodecError.self) { try codec.decode(bytes) }
            }
        }
        var legacy = object
        legacy["version"] = 0
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
        #expect(throws: CodecError.self) { try codec.decode(legacyBytes) }
        var cyclic = object
        cyclic["chainedFrom"] = object["conversation"]
        let cyclicBytes = try JSONSerialization.data(withJSONObject: cyclic)
        #expect(throws: CodecError.self) { try codec.decode(cyclicBytes) }
    }

    @Test func rosterSubstitutionKeepsDuplicateAndImitationLabelsDistinct() {
        let names = [P15.alice: " Alex ", P15.bob: "alex", P15.eve: "Alex (\(P15.alice.fingerprint))"]
        // Duplicates must be detected across all friends, even with one on the sheet.
        let alice = RosterLabels.labels(for: [P15.alice], friends: names)
        let bob = RosterLabels.labels(for: [P15.bob], friends: names)
        let eve = RosterLabels.labels(for: [P15.eve], friends: names)
        #expect(alice != bob && alice != eve)
        #expect(alice[0].contains(P15.alice.fingerprint))
        #expect(bob[0].contains(P15.bob.fingerprint))
        #expect(eve[0].hasSuffix("(\(P15.eve.fingerprint))"))
        let formatter = ValueFormatter(friends: { names })
        #expect(formatter.value(.peers([P15.alice, P15.eve])).split(separator: "\n").count == 2)
    }

    @Test func unverifiedLookalikesShowAllBytesAndCannotBorrowAFriendLabel() throws {
        let lookalike = try PeerID(hex: String(P15.alice.hex.dropLast(2)) + "ab")
        #expect(lookalike.fingerprint == P15.alice.fingerprint)
        let names = [P15.alice: "Alex"]
        let label = try #require(RosterLabels.labels(for: [lookalike], friends: names).first)
        #expect(label.contains(RosterLabels.stranger))
        #expect(label.contains(RosterLabels.fullIdentifier(lookalike)))
        #expect(label != RosterLabels.labels(for: [P15.alice], friends: names)[0])
        #expect(RosterLabels.fullIdentifier(lookalike).filter { $0 != " " }.count == 64)
    }

    @MainActor @Test(arguments: Phase15Attacks.confusableNames.map { $0.1 } + ["Alex", "Alex (trusted)"])
    func peerChosenNameMustNotBecomeOwnerNicknameWithoutReview(name: String) async throws {
        let directory = PairingDirectory(localPeer: P15.alice, candidates: { [] },
            pair: { _, _ in throw PairingFailure.cancelled }, paired: { _ in }, peerForPickedDevice: { _ in P15.eve })
        let model = PairingModel(directory: directory)
        await model.pickedDevice(id: 42, name: name)
        #expect(model.selected?.peer == P15.eve)
        withKnownIssue("https://github.com/oliverrowebardeen/starling-ios/issues/46") {
            #expect(model.nickname.isEmpty, "Peer-controlled device name became the local identity label")
        }
        model.nickname = "My friend Sam"
        await model.pickedDevice(id: 42, name: name)
        #expect(model.nickname == "My friend Sam")
        await model.end()
    }
}
