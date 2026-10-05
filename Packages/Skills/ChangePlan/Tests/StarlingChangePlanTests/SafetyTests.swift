import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

/// Holds callers at one point until the test opens it.
actor Gate {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isOpen = false

    func pass() async {
        arrivals += 1
        let ready = watchers.filter { $0.count <= arrivals }
        watchers.removeAll { $0.count <= arrivals }
        for watcher in ready { watcher.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func arrived(_ count: Int = 1) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held = []
    }
}

/// Holds Outbox's didSend for the first send until the test opens the gate,
/// as a slow audit journal would (issue #105).
actor HeldObserver: OutboxObserver {
    let gate = Gate()
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        await gate.pass()
    }
}

/// Holds the next didSend once armed, as a slow audit journal would.
actor ArmedObserver: OutboxObserver {
    let gate = Gate()
    private var armed = false
    func arm() { armed = true }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        guard armed else { return }
        armed = false
        await gate.pass()
    }
}

@Suite struct SafetyTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake

    /// A suggestion as a friend's phone would send it to Maya.
    static func offer(from sender: PeerID, origin: ConversationID, round: UInt16 = 0, terms: Terms,
                      asked: [PeerID]? = nil, expires: Date = Fixtures.date(minutes: 60)) throws -> Envelope {
        // By default, everyone else in the three-person plan was asked.
        let everyone = [Fixtures.alex, Fixtures.maya, Fixtures.jake].filter { $0 != sender }
        let digest = ChangePlanService.rosterDigest(origin: origin, revision: UInt32(round), suggester: sender, asked: asked ?? everyone)
        return try Envelope(conversation: ConversationID(), sender: sender, recipient: Fixtures.maya, sequence: 0,
                            sentAt: Timestamp(Fixtures.date(minutes: 10)),
                            body: .propose(Proposal(round: round, terms: terms, inReplyTo: digest, expiresAt: Timestamp(expires))),
                     skill: ChangePlan.descriptor.ref, mode: .invite, chainedFrom: origin)
    }

    @Test func aSuggestionMayaCannotTrustOpensNothing() async throws {
        let group = Group()
        let maya = group.phone(self.maya)
        let later = try Terms([.time: .slots([Fixtures.later])])
        let forged = [
            // From someone not in the plan.
            try Self.offer(from: Fixtures.stranger, origin: group.origin, terms: later),
            // Naming a revision the plan is not at.
            try Self.offer(from: alex, origin: group.origin, round: 1, terms: later),
            // For a plan this phone does not hold, without Maya in it.
            try Self.offer(from: alex, origin: ConversationID(), terms: try Terms([.people: .peers([alex, jake])])),
            // Removing someone: the roster drops Jake.
            try Self.offer(from: alex, origin: group.origin, terms: try Terms([.people: .peers([alex, self.maya, Fixtures.sam])])),
            // Changing the place, which belongs to Pick a place.
            try Self.offer(from: alex, origin: group.origin, terms: try Terms([.place: .places([try PlaceChoice(name: PlaceName("Elsewhere"))])])),
            // Changing nothing.
            try Self.offer(from: alex, origin: group.origin, terms: try Terms([.activity: .keywords([Fixtures.boba])])),
            // Already past its window.
            try Self.offer(from: alex, origin: group.origin, terms: later, expires: Fixtures.date(minutes: 5)),
        ]
        for envelope in forged { await maya.service.handle(.message(envelope)) }
        await group.network.settle()
        #expect(await maya.changes().isEmpty)
        #expect(await maya.transport.sent.isEmpty)
        await group.network.shutdown()
    }

    @Test func aQuietAskIsIgnored() async throws {
        let group = Group()
        let maya = group.phone(self.maya)
        let quiet = try Envelope(conversation: ConversationID(), sender: alex, recipient: self.maya, sequence: 0, sentAt: Timestamp(Fixtures.date(minutes: 10)),
                                 body: .propose(Proposal(round: 0, terms: try Terms([.time: .slots([Fixtures.later])]))),
                                 skill: ChangePlan.descriptor.ref, mode: .askQuietly, chainedFrom: group.origin)
        await maya.service.handle(.message(quiet))
        await group.network.settle()
        #expect(await maya.changes().isEmpty)
        await group.network.shutdown()
    }

    @Test func crossingSuggestionsShowOneCardAtATimeAndChangeNothing() async throws {
        let group = Group()
        let network = group.network
        // Alex and Maya suggest at the same moment, before either hears of the other.
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex, expiresIn: 30)
        try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: maya, expiresIn: 30)
        await network.deliver()
        try await network.until("Jake's card") { await group.openCard(of: jake) != nil }
        await network.settle()
        // Jake sees one; each suggester's own keeps the other's waiting.
        #expect(await group.phone(jake).changes().count == 1)
        #expect(await group.phone(alex).changes().filter { $0.role == .invitee }.isEmpty)
        #expect(await group.phone(maya).changes().filter { $0.role == .invitee }.isEmpty)
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .accept(proposal: 1))
        await network.deliver()
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("all settled") {
            await network.deliver()
            for person in [alex, maya, jake] where await group.phone(person).changes().contains(where: { !$0.state.isFinal && $0.state != .planned }) {
                return false
            }
            return true
        }
        for person in [alex, maya, jake] {
            let plan = try #require(await group.phone(person).plan(group.origin))
            #expect(plan.revision == 0 && plan.time == Fixtures.tonight && plan.activity == Fixtures.boba)
        }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Issue #105: a fast friend's yes arrives while Outbox is still in the
    /// suggester's didSend, before the offer's ID is known. It is held and
    /// counted once the ID is, never dropped as unsolicited.
    @Test func aYesThatArrivesBeforeTheOfferIDIsKnownStillCounts() async throws {
        let held = HeldObserver()
        let group = Group(observer: { person, _ in person == Fixtures.alex ? held : nil })
        let network = group.network
        let suggesting = Task { try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: Fixtures.alex) }
        // Maya's offer is on the wire; Alex's didSend for it is held.
        await held.gate.arrived()
        await network.deliver()
        try await network.until("Maya's card") { await group.openCard(of: Fixtures.maya) != nil }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        await network.deliver()
        #expect(network.transcript == ["Alex > Maya: propose", "Maya > Alex: accept"])
        // Release: Alex records the offer's ID, counts Maya's yes, asks Jake.
        await held.gate.open()
        _ = try await suggesting.value
        await network.deliver()
        try await network.until("Jake's card") { await group.openCard(of: jake) != nil }
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .accept(proposal: 1))
        await network.deliver()
        try await network.until("applied") {
            for person in [alex, maya, jake] where await group.phone(person).plan(group.origin)?.revision != 1 { return false }
            return true
        }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func addingAFriendAsksConsentForWhoIsInItAndIsAudited() async throws {
        let policy = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: PrivacySettings.defaults.disclosureRules))
        let journal = InMemoryEgressJournal()
        let group = Group(extra: [Fixtures.sam],
                          policy: { $0 == Fixtures.alex ? policy : nil },
                          observer: { person, store in person == Fixtures.alex ? EgressRecorder(sink: StoreEgressSink(store: store), journal: journal) : nil })
        let network = group.network
        let link = try await group.suggest(.change(time: nil, activity: nil, adding: Fixtures.sam), by: alex)
        await network.deliver()
        try await network.until("cards") {
            for person in [maya, jake] where await group.openCard(of: person) == nil { return false }
            return true
        }
        // People defaults to Ask me: the roster leaves only after a sheet.
        let sheets = await group.phone(alex).consent.requests
        #expect(sheets.count == 2)
        #expect(sheets.allSatisfy { $0.items.contains { $0.issue == .people } && $0.interaction == link.id })
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("Sam's card") { await group.openCard(of: Fixtures.sam) != nil }
        try await group.phone(Fixtures.sam).service.answer(try await group.card(of: Fixtures.sam).id, with: .accept(proposal: 1))
        await network.deliver()
        try await network.until("applied") { await group.phone(alex).plan(group.origin)?.attendees.peers.count == 4 }
        // What left Alex's phone is recorded on the change, under the plan.
        try await network.until("audited") { await group.phone(alex).interaction(link.id)?.egress.isEmpty == false }
        let timeline = try #require(PlanTimeline(for: group.roots[alex]!.id, in: await group.phone(alex).all(), registry: Fixtures.registry))
        #expect(timeline.entries.map(\.id).contains(link.id))
        #expect(timeline.whatLeft.shared.map(\.topic).contains(.people))
        await network.shutdown()
    }

    @Test func anOpenSuggestionDoesNotSurviveARestart() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards") { await group.openCard(of: maya) != nil }
        // Maya's app restarts with her card open.
        let card = try await group.card(of: maya)
        let fresh = ChangePlanService(outbox: group.phone(maya).outbox, ledger: group.phone(maya).ledger, journal: InMemoryChangePlanJournal(),
                                      holds: PlanChangeHolds(), me: maya, planLookup: { _ in nil })
        await fresh.restore([card])
        #expect(try await group.phone(maya).ledger.isRetired(card.conversation))
        var events = fresh.events.makeAsyncIterator()
        #expect(await events.next() == .lifecycle(card.id, .failed))
        // Alex's suggestion is untouched by it, and still open.
        #expect(await group.phone(alex).interaction(link.id)?.state == .confirmed)
        await fresh.shutdown()
        await network.shutdown()
    }

    /// Review of PR #111, finding A: withdrawing a suggestion that waited
    /// behind another must not read as its sender leaving the plan.
    @Test func withdrawingAQueuedSuggestionRemovesNobody() async throws {
        let group = Group()
        let network = group.network
        // Alex and Maya suggest at once; on Jake's phone Alex's arrives
        // first and Maya's waits behind it.
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        let mayas = try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: maya)
        await network.deliver()
        try await network.until("Jake's card") { await group.openCard(of: jake) != nil }
        await network.settle()
        #expect(await group.phone(jake).changes().count == 1)
        // Maya withdraws hers: Jake's queue drops it, and nobody leaves.
        var withdrawn = try #require(await group.phone(maya).interaction(mayas.id))
        try withdrawn.apply(.withdrawn, at: Timestamp(group.clock.now))
        try await group.phone(maya).store.save(withdrawn)
        await group.phone(maya).service.withdraw(mayas.id)
        await network.deliver()
        await network.settle()
        #expect(network.transcript.contains("Maya > Jake: reject"))
        #expect(await group.phone(jake).plan(group.origin)?.attendees.peers == [alex, maya, jake])
        #expect(await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya, jake])
        // When Alex's settles, Maya's withdrawn one is not shown.
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .pass)
        await network.deliver()
        await network.settle()
        #expect(await group.openCard(of: jake) == nil)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aRejectionThatNamesNothingOpenChangesNothing() async throws {
        let group = Group()
        let maya = group.phone(self.maya)
        // As if Alex's offer was lost and only its withdrawal arrived.
        let stray = try Envelope(conversation: ConversationID(), sender: alex, recipient: self.maya, sequence: 0, sentAt: Timestamp(Fixtures.date(minutes: 10)),
                                 body: .reject(Rejection(proposal: MessageID(), reason: .declinedByOwner)),
                                 skill: ChangePlan.descriptor.ref, mode: .invite, chainedFrom: group.origin)
        await maya.service.handle(.message(stray))
        await group.network.settle()
        #expect(await maya.plan(group.origin)?.attendees.peers == [alex, self.maya, jake])
        #expect(await maya.changes().isEmpty)
        #expect(await maya.transport.sent.isEmpty)
        await group.network.shutdown()
    }

    /// Review of PR #111, finding B: a yes that arrives while the owner's
    /// withdrawal is still going out must not confirm the change.
    @Test func aYesArrivingDuringAWithdrawalConfirmsNothing() async throws {
        let observer = ArmedObserver()
        let group = Group(observer: { person, _ in person == Fixtures.alex ? observer : nil })
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards") {
            for person in [maya, jake] where await group.openCard(of: person) == nil { return false }
            return true
        }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        await network.deliver()
        // Jake says yes; his yes is still on its way when Alex withdraws.
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .accept(proposal: 1))
        var withdrawn = try #require(await group.phone(alex).interaction(link.id))
        try withdrawn.apply(.withdrawn, at: Timestamp(group.clock.now))
        try await group.phone(alex).store.save(withdrawn)
        await observer.arm()
        let service = group.phone(alex).service
        let withdrawing = Task { await service.withdraw(link.id) }
        await observer.gate.arrived()
        // Jake's yes reaches Alex while the withdrawal is held mid-send.
        await network.deliver()
        await observer.gate.open()
        await withdrawing.value
        await network.deliver()
        await network.settle()
        #expect(!network.transcript.contains("Alex > Maya: accept"))
        #expect(!network.transcript.contains("Alex > Jake: accept"))
        for person in [alex, maya, jake] { #expect(await group.phone(person).plan(group.origin)?.revision == 0) }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Another skill (Pick a place) moves every phone's plan to a new place,
    /// revision 0 to 1, while a time change is open.
    static func movePlace(_ group: Group, on people: [PeerID]) async throws {
        for person in people {
            let phone = group.phone(person)
            var root = try #require(await phone.interaction(group.roots[person]!.id))
            let plan = try #require(root.plan)
            root.record(.plan(try plan.updating(place: .some(try PlaceChoice(name: PlaceName("Boba Guys"))))))
            try await phone.store.save(root)
        }
    }

    /// Review of PR #111, finding C: the suggester re-reads the plan before
    /// confirming, and a change whose basis moved never commits a stale plan.
    @Test func aChangeWhoseBasisMovedEndsWithThePlanAsItIs() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards") {
            for person in [maya, jake] where await group.openCard(of: person) == nil { return false }
            return true
        }
        try await Self.movePlace(group, on: [alex, maya, jake])
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("ended") { await group.phone(alex).interaction(link.id)?.state.isFinal == true }
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp))
        await network.deliver()
        try await network.until("cards closed") {
            for person in [maya, jake] where await group.phone(person).changes().contains(where: { !$0.state.isFinal }) { return false }
            return true
        }
        // Every phone keeps the moved plan; nothing was confirmed.
        for person in [alex, maya, jake] {
            let plan = try #require(await group.phone(person).plan(group.origin))
            #expect(plan.revision == 1 && plan.time == Fixtures.tonight && plan.place?.name.rawValue == "Boba Guys")
        }
        #expect(!network.transcript.contains("Alex > Maya: accept"))
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func theCoordinatorEndsASuggestionWhenAnotherSkillMovesThePlan() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards") {
            for person in [maya, jake] where await group.openCard(of: person) == nil { return false }
            return true
        }
        try await Self.movePlace(group, on: [alex, maya, jake])
        // The coordinator tells the skill after applying the place.
        await group.phone(alex).service.planDidChange(group.origin)
        try await network.until("ended") { await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp) }
        await network.deliver()
        try await network.until("cards closed") {
            for person in [maya, jake] where await group.openCard(of: person) != nil { return false }
            return true
        }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Review of PR #111, finding E: the confirmation overtakes Maya's own
    /// yes while it is held at Outbox's didSend; she still says yes first,
    /// then applies, and her card reaches planned.
    @Test func aConfirmationThatOvertakesTheYesWaitsForIt() async throws {
        let observer = ArmedObserver()
        let group = Group(observer: { person, _ in person == Fixtures.maya ? observer : nil })
        let network = group.network
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards") {
            for person in [maya, jake] where await group.openCard(of: person) == nil { return false }
            return true
        }
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .accept(proposal: 1))
        await network.deliver()
        let card = try await group.card(of: maya)
        await observer.arm()
        let service = group.phone(maya).service
        let accepting = Task { try await service.answer(card.id, with: .accept(proposal: 1)) }
        await observer.gate.arrived()
        // Maya's yes is on the wire; Alex confirms before her didSend returns.
        await network.deliver()
        #expect(network.transcript.contains("Alex > Maya: accept"))
        await observer.gate.open()
        try await accepting.value
        await network.deliver()
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        try await network.until("Maya's card planned") { await group.phone(maya).interaction(card.id)?.state == .planned }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Review of PR #111, finding G (accepted as a limit, partly fixed): an
    /// offer put to fewer people than everyone else in the plan opens
    /// nothing, so an honest bug cannot leave phones on different plans.
    @Test func anOfferPutToFewerThanThePlanOpensNothing() async throws {
        let group = Group()
        let maya = group.phone(self.maya)
        let later = try Terms([.time: .slots([Fixtures.later])])
        await maya.service.handle(.message(try Self.offer(from: alex, origin: group.origin, terms: later, asked: [self.maya])))
        await group.network.settle()
        #expect(await maya.changes().isEmpty)
        // The same offer put to everyone else is shown (the control).
        await maya.service.handle(.message(try Self.offer(from: alex, origin: group.origin, terms: later)))
        try await group.network.until("card") { await group.openCard(of: self.maya) != nil }
        await group.network.shutdown()
    }

    /// Issue #114: a confirmation naming the right conversation and offer
    /// but another plan as its parent commits nothing.
    @Test func aConfirmationForAnotherPlanCommitsNothing() async throws {
        let group = Group()
        let network = group.network
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        let offer = try #require(try await group.phone(alex).transport.sent.map { try EnvelopeCodec().decode($0.frame.bytes) }.first { $0.recipient == maya })
        await network.deliver()
        try await network.until("Maya's card") { await group.openCard(of: maya) != nil }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        func confirmation(parent: ConversationID) throws -> Envelope {
            try Envelope(conversation: offer.conversation, sender: alex, recipient: maya, sequence: 99, sentAt: Timestamp(group.clock.now),
                         body: .accept(Acceptance(proposal: offer.id, terms: try Terms([:]))), skill: ChangePlan.descriptor.ref, mode: .invite,
                         chainedFrom: parent)
        }
        await group.phone(maya).service.handle(.message(try confirmation(parent: ConversationID())))
        await network.settle()
        #expect(await group.phone(maya).plan(group.origin)?.revision == 0)
        // The same confirmation for this plan applies (the control).
        await group.phone(maya).service.handle(.message(try confirmation(parent: group.origin)))
        try await network.until("applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        await network.shutdown()
    }
}
