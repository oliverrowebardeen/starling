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

    static func expectPlainNo(_ envelope: Envelope?, about message: MessageID, after previous: Envelope?) {
        guard let envelope, case .reject(let rejection) = envelope.body else {
            Issue.record("expected one rejection, got \(String(describing: envelope?.body.kind))")
            return
        }
        #expect(rejection.reason == .noOverlap)
        #expect(rejection.proposal == message)
        #expect(envelope.version == Envelope.currentVersion)
        #expect(envelope.skill == FindATimeSkill.ref)
        #expect(envelope.mode == .invite)
        #expect(envelope.chainedFrom == nil)
        if let previous {
            #expect(envelope.sequence == previous.sequence + 1, "a gap shows a refused send")
        } else {
            // The conversation's first number is the send time in whole
            // milliseconds (rounded down; Timestamp rounds to nearest).
            let sentAt = UInt64(envelope.sentAt.millisecondsSince1970)
            #expect(envelope.sequence == sentAt || envelope.sequence + 1 == sentAt, "a gap shows a refused send")
        }
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
        try await Task.sleep(for: .milliseconds(60))
        let query = world.envelopes.first { $0.sender == a.id && $0.body.kind == .query }!
        let sent = Self.sent(by: b, in: world)
        #expect(sent.count == 1)
        Self.expectPlainNo(sent.first, about: query.id, after: nil)
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
        try await Task.sleep(for: .milliseconds(60))
        let proposal = world.envelopes.last { $0.sender == a.id && $0.body.kind == .propose }!
        let sent = Self.sent(by: b, in: world)
        #expect(sent.map(\.body.kind) == [.answer, .reject])
        Self.expectPlainNo(sent.last, about: proposal.id, after: sent.first)
        await world.stop()
    }
}
