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
        try await b.waitForState(nil, .ended(.declined))
        let requests = await consent.requests
        #expect(requests.count == 1)
        for disclosure in requests {
            #expect(disclosure.skill == FindATimeSkill.ref)
            #expect(disclosure.items.allSatisfy { $0.issue == .time && $0.category == .availability })
            #expect(Canary.leaks(in: String(describing: disclosure)).isEmpty)
        }
        // Ben's phone sent nothing at all: a declined sheet is a quiet pass.
        try await Task.sleep(for: .milliseconds(60))
        #expect(!world.envelopes.contains { $0.sender == b.id && $0.skill != nil })
        #expect(await b.coordinator.rejected.isEmpty)
        world.clock.advance(hours: 1)
        try await a.waitForState(started, .ended(.nobodyUp))
        await world.stop()
    }

    /// ADR 0019, decision 4 and amendment 10: an answer that only says
    /// which of the friend's own times work, and an acceptance of exactly
    /// what the friend proposed, carry no value of the owner's, so they go
    /// without a sheet whatever the time topic is set to. Ben sets time to
    /// Ask me and is never asked, yet the plan is made.
    @Test func aYesOrNoAnswerAndAnAcceptanceNeedNoSheet() async throws {
        var settings = PrivacySettings()
        try settings.set(.askMe, for: .time)
        let rules = OwnerRules(constraints: .empty, disclosure: settings.disclosureRules)
        let world = World()
        let a = world.phone("Ana")
        let sheet = HeldConsent()
        let b = world.phone("Ben", calendar: FakeCalendarStore(events: Canary.events()), consent: sheet,
                            policyWithFriends: { DeterministicPolicyEngine(ownerRules: rules, pairedPeers: $0) })
        try await world.start()

        let started = try await a.findATime(with: [b])
        let (bCard, _) = try await b.waitForProposal()
        #expect(await sheet.asked == 0)
        #expect(settings.choice(for: .calendarDetails) == .never)
        try await b.accept(bCard)
        try await a.accept(started)
        try await b.waitForState(bCard, .planned)
        #expect(await sheet.asked == 0)
        await world.stop()
    }

    /// Every send names the interaction it belongs to on this phone (Core
    /// v2.1), so the consent sheet suspends the right one.
    @Test func everySendNamesItsInteraction() async throws {
        let world = World()
        let policyA = FixedPolicyEngine(.allow)
        let policyB = FixedPolicyEngine(.allow)
        let a = world.phone("Ana", policy: policyA)
        let b = world.phone("Ben", policy: policyB)
        try await world.start()
        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await a.accept(started)
        try await b.accept(bCard)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)

        for (policy, id) in [(policyA, started), (policyB, bCard)] {
            let sends = await policy.evaluated.filter { $0.envelope.skill != nil }
            #expect(!sends.isEmpty)
            #expect(sends.allSatisfy { $0.context.interaction == id && $0.envelope.mode == .invite })
        }
        let acceptances = await policyB.evaluated.filter { $0.envelope.body.kind == .accept }
        #expect(!acceptances.isEmpty)
        #expect(acceptances.allSatisfy { message in
            guard case .accept(let acceptance) = message.envelope.body, let proposal = message.context.accepting else { return false }
            return proposal.isAcceptedAsOffered(by: acceptance)
        })
        // The starter's confirmation repeats its own terms: no accepting.
        #expect(await policyA.evaluated.filter { $0.envelope.body.kind == .accept }.allSatisfy { $0.context.accepting == nil })
        let answers = await policyB.evaluated.filter { $0.envelope.body.kind == .answer }
        #expect(answers.allSatisfy { message in
            guard case .answer(let answer) = message.envelope.body, let query = message.context.answering else { return false }
            return query.isAnsweredYesOrNo(by: answer)
        })
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
