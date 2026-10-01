@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Reviews of PR #53 (first round, finding 1; second round, findings 2
/// and 3) and ADR 0019 decision 5: the starter must not be able to tell
/// why a friend said no, from the envelopes or from their timing.
/// - While answering, every no is silence: no envelope, whatever the cause,
///   however often the starter retries. The starter ends at its own answer
///   deadline, on a clock the test controls.
/// - At a proposal, a "no plan" follows only the owner's tap and is the same
///   envelope whatever the tap led to: one rejection, reason noOverlap,
///   naming the proposal, numbered with no gap (Core v2.1 numbers an
///   envelope only once it is cleared). A no the agent reaches alone is
///   silent, like an owner who never answers.
@Suite(.serialized)
struct IndistinguishableTests {
    enum Answering: CaseIterable { case busy, standingLimit, refusedByPolicy, pass, declinedSheet }
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

    enum Unanswered: CaseIterable { case standingLimit, ownerNeverAnswers }

    /// At a proposal, a no the agent reaches by itself (an avoided
    /// activity) is silent, exactly like an owner who never taps.
    @Test(arguments: Unanswered.allCases)
    func anAutomaticNoToTheProposalLooksLikeNoAnswer(_ unanswered: Unanswered) async throws {
        let world = World()
        let a = world.phone("Ana")
        let b: Phone = switch unanswered {
        case .standingLimit: world.phone("Ben", standing: try ConstraintSet([.activity: [Constraint(.prefers(liked: [], avoided: [Keyword("stats")]), strength: .soft)]]))
        case .ownerNeverAnswers: world.phone("Ben")
        }
        try await world.start()

        let started = try await a.findATime(with: [b])
        try await eventually("Ben answered") { Self.sent(by: b, in: world).contains { $0.body.kind == .answer } }
        try await eventually("Ana proposed, and retried") {
            world.envelopes.filter { $0.sender == a.id && $0.body.kind == .propose }.count >= 5
        }
        #expect(!Self.sent(by: b, in: world).contains { $0.body.kind != .answer })
        world.clock.advance(hours: 2)
        try await a.waitForState(started, .ended(.expired))
        #expect(!Self.sent(by: b, in: world).contains { $0.body.kind != .answer })
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
        // Every refusal of this proposal names the proposal (finding 2),
        // never the query, whatever the tap led to; one per tap.
        #expect(sent.filter { $0.body.kind == .reject }.count == 1)
        // Answers (one, or replays of it), then plain noes; never an acceptance.
        let kinds = sent.sorted { $0.sequence < $1.sequence }.map(\.body.kind)
        #expect(kinds.first == .answer)
        #expect(!kinds.contains(.accept))
        #expect(kinds.drop { $0 == .answer }.allSatisfy { $0 == .reject })
        Self.expectNoGapsAndPlainNoes(sent, about: proposals)
        await world.stop()
    }
}
