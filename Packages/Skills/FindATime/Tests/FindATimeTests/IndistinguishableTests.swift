@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Reviews of PR #53 (every round) and ADR 0019 decision 5: the starter
/// must not be able to tell why a friend said no, from the envelopes or
/// from their timing. Every no is silence, while answering and at a
/// proposal, whatever the cause and however often the starter retries,
/// exactly like a friend who never touched the card. The starter ends on
/// its own deadlines, on a clock the test controls. "If you pass, they
/// just won't see it" (ADR 0017).
@Suite(.serialized)
struct IndistinguishableTests {
    enum Answering: CaseIterable { case busy, standingLimit, refusedByPolicy, pass, declinedSheet }
    enum Agreeing: CaseIterable { case untouched, pass, refusedByPolicy, declinedSheet, standingLimit }

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

    @Test(arguments: Answering.allCases)
    func everyNoToTheQuestionIsSilence(_ answering: Answering) async throws {
        let world = World()
        let a = world.phone("Ana")
        let b: Phone = switch answering {
        case .busy: world.phone("Ben", calendar: FakeCalendarStore(events: [FakeCalendarEvent(title: "Shift", start: T.at(0), end: T.at(48))]))
        case .standingLimit: world.phone("Ben", standing: try ConstraintSet([.time: [Constraint(.dailyWindow(from: 22 * 60, to: 24 * 60))]]))
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
        // Ben's side ends at once; only his own phone knows why.
        let ended: InteractionState = switch answering {
        case .busy, .standingLimit: .ended(.nobodyUp)
        case .refusedByPolicy: .ended(.blockedByPrivacy)
        case .pass, .declinedSheet: .ended(.declined)
        }
        try await b.waitForState(nil, ended)

        // Ana keeps asking (retries every 20 ms) and hears nothing: the same
        // count, zero, at every moment, whatever the cause.
        try await eventually("Ana retried") {
            world.envelopes.filter { $0.sender == a.id && $0.body.kind == .query }.count >= 5
        }
        #expect(Self.sent(by: b, in: world).isEmpty)
        #expect(await a.coordinator.interaction(started)?.state == .negotiating)

        // The only clock that ends it is Ana's own answer deadline.
        world.clock.advance(hours: 1)
        try await a.waitForState(started, .ended(.nobodyUp))
        try await Task.sleep(for: .milliseconds(60))
        #expect(Self.sent(by: b, in: world).isEmpty)
        await world.stop()
    }

    /// The wire trace for every no at a proposal, compared with a card the
    /// friend never touched: the friend's only envelopes are its answer
    /// (and replays of it), nothing after, and the starter's request ends
    /// only when its own confirm deadline passes.
    @Test(arguments: Agreeing.allCases)
    func everyNoToTheProposalIsLikeNoAnswer(_ agreeing: Agreeing) async throws {
        let world = World()
        let a = world.phone("Ana")
        let b: Phone = switch agreeing {
        case .untouched, .pass: world.phone("Ben")
        case .refusedByPolicy: world.phone("Ben", policy: Self.denies(.accept))
        case .declinedSheet: world.phone("Ben", policy: Self.asks(.accept), consent: ScriptedConsentProvider(.declined))
        case .standingLimit: world.phone("Ben", standing: try ConstraintSet([.activity: [Constraint(.prefers(liked: [], avoided: [Keyword("stats")]), strength: .soft)]]))
        }
        try await world.start()

        let started = try await a.findATime(with: [b])
        try await eventually("Ben answered") { Self.sent(by: b, in: world).contains { $0.body.kind == .answer } }
        switch agreeing {
        case .pass:
            let (card, _) = try await b.waitForProposal()
            try await b.service.answer(card, with: .pass)
        case .refusedByPolicy, .declinedSheet:
            let (card, _) = try await b.waitForProposal()
            try await b.accept(card)
        case .untouched, .standingLimit:
            break
        }
        let ended: InteractionState? = switch agreeing {
        case .untouched: nil
        case .pass, .declinedSheet: .ended(.declined)
        case .refusedByPolicy: .ended(.blockedByPrivacy)
        case .standingLimit: .ended(.nobodyUp)
        }
        if let ended { try await b.waitForState(nil, ended) }

        // Ana keeps sending the proposal and hears nothing back but answers.
        try await eventually("Ana proposed, and retried") {
            world.envelopes.filter { $0.sender == a.id && $0.body.kind == .propose }.count >= 5
        }
        #expect(Self.sent(by: b, in: world).allSatisfy { $0.body.kind == .answer })
        #expect(await a.coordinator.interaction(started)?.state == .proposed)

        world.clock.advance(hours: 2)
        try await a.waitForState(started, .ended(.expired))
        try await Task.sleep(for: .milliseconds(60))
        #expect(Self.sent(by: b, in: world).allSatisfy { $0.body.kind == .answer })
        await world.stop()
    }
}
