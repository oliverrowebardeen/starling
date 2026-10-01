@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Synchronization
import Testing

/// ADR 0013, decision 5: event titles, places, notes, and people never
/// leave the device and never enter a prompt. Both phones keep calendars
/// full of marker strings; the tests search everything a peer, the policy,
/// the consent sheet, the lifecycle, or the model could see.
@Suite(.serialized)
struct PrivacyTests {
    @Test func eventDetailsNeverReachASendAPromptOrAnEvent() async throws {
        let world = World()
        let policy = FixedPolicyEngine(.allow)
        let a = world.phone("Ana", calendar: FakeCalendarStore(events: Canary.events() + Canary.events(day: 1)), policy: policy)
        let b = world.phone("Ben", calendar: FakeCalendarStore(events: Canary.events()), policy: policy)
        let c = world.phone("Cy", calendar: FakeCalendarStore(status: .denied), policy: policy)
        try await world.start()

        let started = try await a.findATime(with: [b, c], range: [T.slot(8, 48)])
        let (cAsked, question) = try await c.waitForQuestion()
        try await c.reply(cAsked, question: question.revision, question.slots)
        let (_, proposal) = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        let (cCard, _) = try await c.waitForProposal()
        try await a.accept(started)
        try await b.accept(bCard)
        try await c.accept(cCard)
        try await a.waitForState(started, .planned)

        // The model sees only ProposalFacts; capture every prompt input.
        let prompts = Mutex<[ProposalFacts]>([])
        let model = ScriptedSkillModel(onProposal: { facts in
            prompts.withLock { $0.append(facts) }
            return "Model sentence"
        })
        for phone in [a, b, c] {
            let writer = FindATimeProposalWriter(model: model, localPeer: phone.id, timeZone: T.utc, nickname: { _ in "Friend" })
            for interaction in await phone.coordinator.all() {
                if let card = interaction.proposal { #expect(await writer.sentence(for: card) == "Model sentence") }
            }
        }
        #expect(prompts.withLock(\.count) == 3)

        var seen: [String] = [world.wireText]
        seen += world.envelopes.map { String(describing: $0) }
        seen += await policy.evaluated.map { String(describing: $0) }
        seen += prompts.withLock { $0 }.map { String(describing: $0) }
        for phone in [a, b, c] {
            seen += await phone.coordinator.log.map { String(describing: $0) }
            seen += try await phone.checkpoints.all().map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        }
        for text in seen { #expect(Canary.leaks(in: text).isEmpty, "\(Canary.leaks(in: text))") }

        // Busy time itself is not offered: no slot overlapping an event is
        // on the wire from a phone whose calendar has it.
        let busy = Canary.events() + Canary.events(day: 1)
        for envelope in world.envelopes where envelope.sender == a.id {
            for slot in Self.slots(in: envelope.body) {
                #expect(!busy.contains { $0.start < slot.end && $0.end > slot.start }, "Ana offered a busy time \(slot)")
            }
        }
        #expect(proposal.plan?.time != nil)
        await world.stop()
    }

    /// The consent sheet and "What left your phone" show the same items the
    /// real policy computes. With time set to Ask me, those items are times
    /// only, and declining the sheet is a pass that the starter cannot tell
    /// from having no time free.
    @Test func consentShowsOnlyTimesAndADeclineIsAQuietPass() async throws {
        var settings = PrivacySettings()
        try settings.set(.askMe, for: .time)
        let rules = OwnerRules(constraints: .empty, disclosure: settings.disclosureRules)
        let world = World()
        let a = world.phone("Ana", calendar: FakeCalendarStore(events: Canary.events()))
        let consent = ScriptedConsentProvider(.declined)
        let b = world.phone("Ben", calendar: FakeCalendarStore(events: Canary.events()),
                            policy: DeterministicPolicyEngine(ownerRules: rules), consent: consent)
        try await world.start()

        let started = try await a.findATime(with: [b])
        try await a.waitForState(started, .ended(.nobodyUp))
        let requests = await consent.requests
        #expect(requests.count == 1)
        for disclosure in requests {
            #expect(disclosure.skill == FindATimeSkill.ref)
            #expect(disclosure.items.allSatisfy { $0.issue == .time && $0.category == .availability })
            #expect(Canary.leaks(in: String(describing: disclosure)).isEmpty)
        }
        // Ben's phone sent a plain "no plan", never his answer.
        let fromBen = world.envelopes.filter { $0.sender == b.id && $0.skill != nil }.map(\.body.kind)
        #expect(fromBen == [.reject])
        // Ben's sheet opened and his decline ended his side as declined.
        try await b.waitForState(nil, .ended(.declined))
        #expect(await b.coordinator.rejected.isEmpty)
        await world.stop()
    }

    static func slots(in body: MessageBody) -> [TimeSlot] {
        let values: [IssueValue] = switch body {
        case .query(let query): [query.candidates]
        case .answer(let answer): answer.acceptable.map { [$0] } ?? []
        case .propose(let proposal), .counter(let proposal): Array(proposal.terms.values.values)
        case .accept(let acceptance): Array(acceptance.terms.values.values)
        default: []
        }
        return values.flatMap { value -> [TimeSlot] in
            if case .slots(let slots) = value { return slots }
            return []
        }
    }
}
