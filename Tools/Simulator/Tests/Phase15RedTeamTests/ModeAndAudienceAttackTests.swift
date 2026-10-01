import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct ModeAndAudienceAttackTests {
    @Test(arguments: SampleSkills.all)
    func malformedModesAndRetiredVersionNeverReachInbox(skill: SkillDescriptor) async throws {
        let conversation = ConversationID()
        let valid = try Envelope(conversation: conversation, sender: P15.alice, recipient: P15.bob,
            sequence: 7, sentAt: P15.now, body: .propose(Proposal(round: 0, terms: P15.proposal(1).terms)),
            skill: skill.ref, mode: skill.defaultSendMode)
        let codec = EnvelopeCodec()
        let json = try #require(JSONSerialization.jsonObject(with: codec.encode(valid)) as? [String: Any])
        var mutations: [[String: Any]] = []
        for mode: Any in [NSNull(), "", "askQuietly", "ASK_QUIETLY", "invite\n", 1, ["invite"]] {
            var changed = json; changed["mode"] = mode; mutations.append(changed)
        }
        var missing = json; missing.removeValue(forKey: "mode"); mutations.append(missing)
        var orphan = json; orphan.removeValue(forKey: "skill"); mutations.append(orphan)
        for version in [0, 1, 3] {
            var changed = json; changed["version"] = version; mutations.append(changed)
        }
        var retiredWithoutMode = json
        retiredWithoutMode["version"] = 1
        retiredWithoutMode.removeValue(forKey: "mode")
        mutations.append(retiredWithoutMode)
        for mutation in mutations {
            let inbox = Inbox(localPeer: P15.bob, now: { P15.date })
            let data = try JSONSerialization.data(withJSONObject: mutation)
            #expect(throws: CodecError.self) { try codec.decode(data) }
            guard case .failure(.codec) = try await inbox.accept(Frame(data), from: P15.alice) else {
                Issue.record("Malformed mode/version reached Inbox"); continue
            }
            // A rejected message cannot reserve its sequence and suppress a valid request.
            #expect(try await inbox.accept(Frame(codec.encode(valid)), from: P15.alice).get() == valid)
        }
        var legacy = json
        legacy["version"] = 0
        legacy.removeValue(forKey: "mode")
        legacy.removeValue(forKey: "skill")
        #expect(try codec.decode(JSONSerialization.data(withJSONObject: legacy)).version == 0)
    }

    @Test func quietModeCannotBeDeclaredByAnInviteOnlyBuildingBlock() throws {
        #expect(SampleSkills.downFor.sendModes == [.askQuietly, .invite])
        for skill in SampleSkills.all {
            #expect(skill.defaultSendMode == skill.sendModes[0])
            if skill.id != .downFor { #expect(skill.sendModes == [.invite]) }
            for modes: [SendMode] in [[], [.invite, .invite], [.askQuietly]] {
                if modes == [.askQuietly] && skill.buildingBlock == .mutualReveal { continue }
                #expect(throws: ValidationError.self) {
                    try SkillDescriptor(ref: skill.ref, wording: skill.wording, buildingBlock: skill.buildingBlock,
                        topicsUsed: skill.topicsUsed, topicsRequired: skill.topicsRequired, produces: skill.produces,
                        intent: skill.intent, sendModes: modes)
                }
            }
        }
    }

    @Test func explicitExceptionsAndUnknownGroupsCannotBeOverriddenByStandingRules() throws {
        let group = try FriendGroup(name: "private climbing group", members: [P15.bob, P15.eve])
        let book = AudienceBook(closeFriends: [P15.bob, P15.eve], groups: [group],
            rules: [P15.alice: .alwaysInclude, P15.bob: .quietOnly, P15.eve: .neverInclude])
        let friends = [P15.eve, P15.bob, P15.alice]
        let cases: [(Audience, SendMode, [PeerID])] = [
            (.allFriends, .invite, [P15.alice]),
            (.allFriends, .askQuietly, [P15.bob, P15.alice]),
            (.closeFriends, .invite, [P15.alice]),
            (.closeFriends, .askQuietly, [P15.bob, P15.alice]),
            (.group(group.id), .invite, [P15.alice]),
            (.group(group.id), .askQuietly, [P15.bob, P15.alice]),
            (.everyoneExcept([P15.alice, P15.alice]), .invite, []),
            (.everyoneExcept([P15.alice]), .askQuietly, [P15.bob]),
            (.group(GroupID()), .askQuietly, []),
            // Explicit picks override standing rules, but not pairing or support.
            (.picked([P15.alice, P15.bob, P15.eve, P15.bob]), .invite, friends),
        ]
        let restored = try JSONDecoder().decode(AudienceBook.self, from: JSONEncoder().encode(book))
        for (audience, mode, expected) in cases {
            #expect(audience.resolve(mode: mode, friends: friends, book: restored, canRun: { _ in true }) == expected)
            #expect(audience.resolve(mode: mode, friends: friends, book: restored, canRun: { $0 != P15.bob }) == expected.filter { $0 != P15.bob })
        }
        #expect(Audience.picked([P15.alice, P15.eve]).resolve(mode: .invite, friends: [P15.alice], book: book, canRun: { _ in true }) == [P15.alice])
    }

    @Test func peerChainHintNeverBecomesOwnerOptInOrChangesParticipants() throws {
        var invitee = P15.interaction(SampleSkills.swapPhotos)
        let parent = ConversationID()
        let snapshot = invitee
        try invitee.setFriendChainHint(parent)
        invitee = try P15.restart(invitee)
        #expect(invitee.friendChainHint == parent)
        #expect(invitee.chain == nil && invitee.state == snapshot.state)
        #expect(invitee.participants == snapshot.participants)
        #expect(invitee.artifacts.isEmpty && invitee.egress.isEmpty)
        let beforeInvalid = invitee
        #expect(throws: ValidationError.self) { try invitee.setFriendChainHint(invitee.conversation) }
        #expect(invitee == beforeInvalid)
        var initiator = Interaction(skill: SampleSkills.swapPhotos.ref, role: .initiator,
                                    participants: [P15.alice, P15.bob], createdAt: P15.now)
        #expect(throws: ValidationError.self) { try initiator.setFriendChainHint(parent) }
        #expect(initiator.chain == nil && initiator.friendChainHint == nil)
    }
}
