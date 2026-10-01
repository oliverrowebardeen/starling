import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingPolicy
import StarlingTransport
import Testing

/// Privacy topics through the real policy engine (ADR 0014).
@Suite("Privacy topics", .serialized)
struct PrivacyTests {
    func policy(_ choices: [PrivacyTopic: SharingChoice]) throws -> DeterministicPolicyEngine {
        DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: try PrivacySettings(choices).disclosureRules))
    }

    @Test func theConsentSheetShowsOnlyTheFittingPlacesAndTheRoster() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let askMe = try policy([:])
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: askMe)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20, needs: ["vegetarian"]), policy: askMe)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        try await oliver.accept(in: conversation)
        #expect(await maya.reaches(.planned, in: conversation))

        // Maya's sheets: her list (Boba Guys only), then her yes with the
        // roster. Never a budget or a diet.
        let sheets = maya.consent.asked.withLock { $0 }
        let items = sheets.flatMap(\.items)
        #expect(items.contains(DisclosedItem(category: .terms, issue: .place, value: .places([Venues.bobaGuys.choice]))))
        #expect(items.contains(DisclosedItem(category: .terms, issue: .people, value: .peers([oliver.id, maya.id]))))
        #expect(items.allSatisfy { $0.issue != .budget && $0.issue != .diet })
        #expect(sheets.allSatisfy { $0.conversation == conversation && $0.skill == PickAPlaceSkill.ref })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func placeSetToNeverBlocksTheOrganizer() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: try policy([.place: .never]))
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await oliver.reaches(.ended(.blockedByPrivacy), in: conversation))
        #expect(await group.wire.sent(by: oliver.id).allSatisfy { $0.body.kind == .reject })
        #expect(await maya.interaction(conversation) == nil)
    }

    @Test func placeSetToNeverOnAFriendsPhoneLooksLikeSilence() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                            answerWindow: .milliseconds(500), confirmWindow: .seconds(3))
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, policy: try policy([.place: .never]), configuration: quick)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.ended(.blockedByPrivacy), in: conversation))
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func passingOnTheConsentSheetSendsNothing() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, policy: try policy([:]), consent: .declined)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.ended(.declined), in: conversation))
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendTheOnDeviceRuleExcludesIsLeftOut() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        // Oliver allows only on-device agents; Jake's card says his model
        // runs in the cloud. Only the sends to Jake are refused.
        let onlyOnDevice = DeterministicPolicyEngine(
            ownerRules: OwnerRules(constraints: .empty, disclosure: try PrivacySettings([.place: .share, .people: .share]).disclosureRules),
            onlyOnDeviceAgents: true
        )
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: onlyOnDevice)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let jake = Phone("Jake", hub: hub, maps: maps, model: .thirdPartyCloud(provider: "acme"))
        let group = try await Group([oliver, maya, jake], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await oliver.interaction(conversation)?.proposal?.participants == [oliver.id, maya.id])
        for phone in [oliver, maya] { try await phone.accept(in: conversation) }
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await group.wire.sent(to: jake.id).isEmpty)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func sharingWithOnDeviceFriendsNeedsNoSheet() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let store = InMemoryPairedPeerStore()
        let share = DeterministicPolicyEngine(
            ownerRules: OwnerRules(constraints: .empty, disclosure: try PrivacySettings([.place: .share, .people: .share]).disclosureRules),
            pairedPeers: store
        )
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: share)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        try await store.save(PairedPeer(publicKey: maya.key, nickname: "Maya", pairedAt: Timestamp(Date())))
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        for phone in [oliver, maya] { try await phone.accept(in: conversation) }
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(oliver.consent.asked.withLock { $0 }.isEmpty)
    }
}
