@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Review of PR #53, finding 1, and ADR 0019 decision 5: every way a
/// friend can end up not answering, or not agreeing, looks the same to the
/// starter. These tests compare the friend's whole envelopes across the
/// cases: one rejection, reason noOverlap, naming the starter's message,
/// numbered with no gap (Core v2.1 numbers an envelope only once it is
/// cleared), sent in the same mode with nothing else.
@Suite(.serialized)
struct IndistinguishableTests {
    enum Answering: CaseIterable { case busy, refusedByPolicy, pass, declinedSheet }
    enum Agreeing: CaseIterable { case pass, refusedByPolicy, declinedSheet }

    static func asks(_ kind: MessageBody.Kind) -> FixedPolicyEngine {
        FixedPolicyEngine(decide: { message in
            guard message.envelope.body.kind == kind else { return .allow }
            return .needsConsent(Disclosure(recipient: message.envelope.recipient, recipientModel: nil, items: [],
                                            conversation: message.envelope.conversation, skill: message.envelope.skill,
                                            interaction: message.context.interaction))
        })
    }

    static func denies(_ kind: MessageBody.Kind) -> FixedPolicyEngine {
        FixedPolicyEngine(decide: { message in
            message.envelope.body.kind == kind ? .deny(PolicyViolation(rule: "disclosure.never")) : .allow
        })
    }

    /// The friend's envelopes in the starter's conversation.
    static func sent(by friend: Phone, in world: World) -> [Envelope] {
        world.envelopes.filter { $0.sender == friend.id && $0.skill != nil }
    }

    /// The friend's envelopes, in order: the conversation's first number
    /// starts at the send time, and each next one is one more, so no
    /// refused send left a gap. Retries may repeat a message (the starter
    /// retried before the reply arrived); every rejection is the plain one.
    static func expectNoGapsAndPlainNoes(_ sent: [Envelope], about starterMessages: Set<MessageID>) {
        let ordered = sent.sorted { $0.sequence < $1.sequence }
        guard let first = ordered.first else { Issue.record("the friend sent nothing"); return }
        // Whole milliseconds, rounded down; Timestamp rounds to nearest.
        let sentAt = UInt64(first.sentAt.millisecondsSince1970)
        #expect(first.sequence == sentAt || first.sequence + 1 == sentAt, "a gap shows a refused send")
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            #expect(next.sequence == previous.sequence + 1, "a gap shows a refused send")
        }
        for envelope in ordered {
            #expect(envelope.version == Envelope.currentVersion)
            #expect(envelope.skill == FindATimeSkill.ref)
            #expect(envelope.mode == .invite)
            #expect(envelope.chainedFrom == nil)
            if case .reject(let rejection) = envelope.body {
                #expect(rejection.reason == .noOverlap)
                #expect(starterMessages.contains(rejection.proposal))
            }
        }
        #expect(ordered.last?.body.kind == .reject)
    }

    @Test(arguments: Answering.allCases)
    func everyNoToTheQuestionLooksTheSame(_ answering: Answering) async throws {
        let world = World()
        let a = world.phone("Ana")
        let b: Phone = switch answering {
        case .busy: world.phone("Ben", calendar: FakeCalendarStore(events: [FakeCalendarEvent(title: "Shift", start: T.at(0), end: T.at(48))]))
        case .refusedByPolicy: world.phone("Ben", policy: Self.denies(.answer))
        case .pass: world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        case .declinedSheet: world.phone("Ben", policy: Self.asks(.answer), consent: ScriptedConsentProvider(.declined))
        }
        try await world.start()

        let started = try await a.findATime(with: [b])
        if answering == .pass {
            let (asked, _) = try await b.waitForQuestion()
            try await b.service.answer(asked, with: .pass)
        }
        try await a.waitForState(started, .ended(.nobodyUp))
        // The hub records deliveries on its own task: wait for the rejection,
        // then a moment more so anything sent after it would show too.
        try await eventually("Ben's rejection on the wire") { Self.sent(by: b, in: world).contains { $0.body.kind == .reject } }
        try await Task.sleep(for: .milliseconds(60))
        let queries = Set(world.envelopes.filter { $0.sender == a.id && $0.body.kind == .query }.map(\.id))
        let sent = Self.sent(by: b, in: world)
        // Nothing but plain noes: no answer ever left.
        #expect(sent.allSatisfy { $0.body.kind == .reject })
        Self.expectNoGapsAndPlainNoes(sent, about: queries)
        // Only Ben's own phone knows why.
        let ended = await b.coordinator.invitee()?.state
        switch answering {
        case .busy: #expect(ended == .ended(.nobodyUp))
        case .refusedByPolicy: #expect(ended == .ended(.blockedByPrivacy))
        case .pass, .declinedSheet: #expect(ended == .ended(.declined))
        }
        await world.stop()
    }

    @Test(arguments: Agreeing.allCases)
    func everyNoToTheProposalLooksTheSame(_ agreeing: Agreeing) async throws {
        let world = World()
        let a = world.phone("Ana")
        let b: Phone = switch agreeing {
        case .pass: world.phone("Ben")
        case .refusedByPolicy: world.phone("Ben", policy: Self.denies(.accept))
        case .declinedSheet: world.phone("Ben", policy: Self.asks(.accept), consent: ScriptedConsentProvider(.declined))
        }
        try await world.start()

        let started = try await a.findATime(with: [b])
        let (card, _) = try await b.waitForProposal()
        if agreeing == .pass { try await b.service.answer(card, with: .pass) } else { try await b.accept(card) }
        try await a.waitForState(started, .ended(.nobodyUp))
        try await eventually("Ben's rejection on the wire") { Self.sent(by: b, in: world).contains { $0.body.kind == .reject } }
        try await Task.sleep(for: .milliseconds(60))
        let proposals = Set(world.envelopes.filter { $0.sender == a.id && $0.body.kind == .propose }.map(\.id))
        let sent = Self.sent(by: b, in: world)
        // Answers (one, or replays of it), then plain noes; never an acceptance.
        let kinds = sent.sorted { $0.sequence < $1.sequence }.map(\.body.kind)
        #expect(kinds.first == .answer)
        #expect(!kinds.contains(.accept))
        #expect(kinds.drop { $0 == .answer }.allSatisfy { $0 == .reject })
        Self.expectNoGapsAndPlainNoes(sent, about: proposals)
        await world.stop()
    }
}
