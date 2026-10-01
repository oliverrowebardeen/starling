#if DEBUG
// Debug builds only. StarlingFakes includes the insecure PSI stub and
// scripted doubles, so nothing outside `#if DEBUG` may import it (ADR 0140).
import Foundation
import Observation
import StarlingAgent
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingNegotiation
import StarlingTransport

/// The Debug composition: the real model, rules file, lane G policy, and
/// lane F's DownNegotiator, with fakes only where lanes have not delivered
/// (ADR 0144). Until lane E1's secure channel exists, the owner's Down runs
/// over an in-process Loopback hub against a simulated friend, so the whole
/// Down journey (PSI, consent sheets, matching, notifications) runs on one
/// phone or the Simulator.
@MainActor
final class DebugHarness {
    static let scriptedModelKey = "dev.scriptedModel"

    let peers: InMemoryPairedPeerStore
    let usesScriptedModel: Bool
    let hub = LoopbackHub()
    /// This phone on the Loopback hub. Its ID is derived from a key, like a
    /// real Starling peer, so the simulated friend can pair with it.
    let owner: PairedPeer
    let transport: LoopbackTransport
    /// Created once: the transport's event stream has a single consumer.
    let inboxEvents: AsyncStream<InboxEvent>
    let simFriend: SimulatedFriend
    /// Fixed per launch so a repeated demo send has an identical disclosure
    /// and the consent memory can be seen.
    let sampleStart: Date
    private var pairingCount = 0

    init(peers: [PairedPeer] = [], defaults: UserDefaults = .standard) {
        usesScriptedModel = defaults.bool(forKey: Self.scriptedModelKey)
        owner = Self.randomPeer(nickname: "This phone")
        transport = LoopbackTransport(localPeer: owner.id, hub: hub)
        inboxEvents = Inbox(localPeer: owner.id).events(from: transport)
        simFriend = SimulatedFriend(hub: hub, owner: owner, card: LiveServices.agentCard(locality: .onDevice))
        self.peers = InMemoryPairedPeerStore([simFriend.peer] + peers)
        sampleStart = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.up) * 3600)
        let simFriend = simFriend
        Task { await simFriend.start() }
    }

    func services(rules: any RulesStore = LiveServices.rulesStore(), notifier: any MatchNotifier = UserNotificationsNotifier.shared) -> AppServices {
        let agent: any AgentModel = usesScriptedModel ? Self.scriptedModel() : FoundationModelsAgent()
        let peers = peers
        let ownerID = owner.id
        return AppServices(
            agent: agent,
            rules: rules,
            peers: peers,
            makeDownService: { outbox in
                // docs/requests/F.md, answers to lane H: the app's Outbox, and
                // the insecure PSI stub until Nightjar.
                DownNegotiator(localPeer: ownerID, outbox: outbox, pairedPeers: peers, model: agent, psi: InsecurePSIStub())
            },
            makePairingSession: { await DebugHarness.scriptedPairing() },
            inboxEvents: inboxEvents,
            makePolicy: LiveServices.policy(peers: peers),
            auditLog: LiveServices.auditLog,
            transport: transport,
            agentCard: LiveServices.agentCard(locality: agent.descriptor.locality),
            downMatchingIsPrivate: InsecurePSIStub().descriptor.isPrivate,
            describeDownError: LiveServices.describeDownError,
            presentConsent: LiveServices.presentConsent,
            notifier: notifier,
            localNetwork: BonjourLocalNetworkPrompter()
        )
    }

    /// A ceremony that shows a random code and pairs with a new random key.
    static func scriptedPairing() -> any PairingSession {
        let code = String(format: "%03d %03d", Int.random(in: 0...999), Int.random(in: 0...999))
        return ScriptedPairingSession(code: code, peer: randomPeer(nickname: "Test friend"))
    }

    static func randomPeer(nickname: String) -> PairedPeer {
        let key = try! IdentityPublicKey(bytes: Data((0..<IdentityPublicKey.byteCount).map { _ in UInt8.random(in: .min ... .max) }))
        return try! PairedPeer(publicKey: key, nickname: nickname, pairedAt: Timestamp(Date()))
    }

    /// Stands in for the on-device model where it cannot run (the Simulator,
    /// ineligible phones). Always returns the same rules, including one
    /// keyword ("karaoke") that is rarely in what was typed, so the review
    /// screen's "not in your words" flag can be seen.
    static func scriptedModel() -> ScriptedAgentModel {
        ScriptedAgentModel(onInterpret: { _, context in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = context.timeZone
            let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: context.now) ?? context.now
            let slot = try TimeSlot(start: evening, end: evening.addingTimeInterval(4 * 3600))
            return OwnerRules(
                constraints: try ConstraintSet([
                    .time: [try Constraint(.within([slot]))],
                    .activity: [try Constraint(.prefers(liked: [try Keyword("food"), try Keyword("karaoke")], avoided: []))],
                    .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))],
                ]),
                disclosure: [DisclosureRule(issue: .time, action: .allowOnDevicePeers)]
            )
        }, onDecide: { _ in .accept })
    }

    // MARK: Simulation (Developer screen)

    func addSampleFriend() async {
        pairingCount += 1
        try? await peers.save(Self.randomPeer(nickname: ["Maya", "Sam", "Jordan", "Priya", "Alex"][(pairingCount - 1) % 5]))
    }

    /// Sends a sample proposal to the first friend through the app's Outbox:
    /// lane G's policy, the consent sheet, and the audit log, over the
    /// recording transport. Returns what happened in plain words.
    func sendSample(through outbox: Outbox?) async -> String {
        guard let outbox else { return "This build has no Outbox." }
        guard let friend = try? await peers.all().first, let proposal = try? Proposal(round: 0, terms: Self.sampleTerms(start: sampleStart)) else {
            return "Add a friend first."
        }
        do {
            try await outbox.send(.propose(proposal), to: friend.id, conversation: ConversationID())
            return "Sent to \(friend.nickname)."
        } catch {
            return SendFailureMessage.text(for: error) ?? "Failed: \(error)"
        }
    }

    /// Core v1.1's refusal when the policy's answer changes while the owner
    /// decides. Lane G's policy computes the same disclosure from the same
    /// message, so a real rule edit ends in a denial instead; this demo uses
    /// a stand-in policy whose re-check returns a different disclosure.
    func sendWithPolicyChangingDuringConsent(through consent: any ConsentProvider) async -> String {
        guard let friend = try? await peers.all().first,
              let asked = try? Self.sampleDisclosure(to: friend.id, start: sampleStart, budgetMinorUnits: 1800),
              let changed = try? Self.sampleDisclosure(to: friend.id, start: sampleStart, budgetMinorUnits: 2500),
              let proposal = try? Proposal(round: 0, terms: Self.sampleTerms(start: sampleStart))
        else { return "Add a friend first." }
        let outbox = Outbox(transport: transport, policy: DemoPolicy(first: asked, recheck: changed), consent: consent)
        do {
            try await outbox.send(.propose(proposal), to: friend.id, conversation: ConversationID())
            return "Sent to \(friend.nickname)."
        } catch {
            return SendFailureMessage.text(for: error) ?? "Failed: \(error)"
        }
    }

    static func sampleTerms(start: Date = Date().addingTimeInterval(3600)) throws -> Terms {
        try Terms([
            .time: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(2 * 3600))]),
            .activity: .keywords([try Keyword("boba run")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
        ])
    }

    static func sampleDisclosure(to peer: PeerID, start: Date, budgetMinorUnits: Int64 = 1500) throws -> Disclosure {
        Disclosure(recipient: peer, recipientModel: .onDevice, items: [
            DisclosedItem(category: .psi, issue: .time, value: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(4 * 3600))])),
            DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("food")])),
            DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: budgetMinorUnits))),
        ])
    }
}

/// A second phone in the same process: lane F's DownNegotiator on its own
/// Loopback transport, paired with this phone. It approves its own consent
/// and allows every send, because only this phone's side should exercise
/// lane G's policy and the consent sheet.
@MainActor
@Observable
final class SimulatedFriend {
    let peer: PairedPeer
    private(set) var state = "Not down"
    private(set) var inRange = true
    private let ownerID: PeerID
    private let hub: LoopbackHub
    private let transport: LoopbackTransport
    private let outbox: Outbox
    private let negotiator: DownNegotiator
    private let card: AgentCard
    private var started = false

    init(hub: LoopbackHub, owner: PairedPeer, card: AgentCard) {
        peer = DebugHarness.randomPeer(nickname: "Sim friend")
        ownerID = owner.id
        self.hub = hub
        self.card = card
        transport = LoopbackTransport(localPeer: peer.id, hub: hub)
        outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
        negotiator = DownNegotiator(
            localPeer: peer.id,
            outbox: outbox,
            pairedPeers: InMemoryPairedPeerStore([owner]),
            model: ScriptedAgentModel(onDecide: { _ in .accept }),
            psi: InsecurePSIStub()
        )
    }

    func start() async {
        guard !started else { return }
        started = true
        let events = Inbox(localPeer: peer.id).events(from: transport)
        let negotiator = negotiator
        let outbox = outbox
        let card = card
        Task {
            for await event in events {
                if case .peerAvailable(let other) = event {
                    Task { _ = try? await outbox.send(.hello(card), to: other, conversation: ConversationID()) }
                }
                await negotiator.handle(event)
            }
        }
        Task { [weak self] in
            for await event in negotiator.events { self?.show(event) }
        }
        try? await transport.start()
    }

    /// Free for the next eight hours, wants food or a boba run, up to $20.
    func goDown(_ level: DownLevel) async {
        let now = Date()
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.up) * 1800)
        let end = start.addingTimeInterval(8 * 3600)
        do {
            let rules = OwnerRules(constraints: try ConstraintSet([
                .time: [try Constraint(.within([try TimeSlot(start: start, end: end)]))],
                .activity: [try Constraint(.prefers(liked: [try Keyword("food"), try Keyword("boba run")], avoided: []))],
                .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 2000)))],
            ]))
            try await negotiator.setIntent(DownIntent(rules: rules, level: level, expiresAt: Timestamp(end)))
            state = level == .down ? "Down: food or boba, up to $20, next 8 hours" : "Maybe: food or boba, up to $20, next 8 hours"
        } catch {
            state = "Couldn't go down: \(error)"
        }
    }

    func withdraw() async {
        await negotiator.clearIntent()
    }

    func setInRange(_ inRange: Bool) async {
        if inRange { await hub.heal(peer.id, ownerID) } else { await hub.partition(peer.id, ownerID) }
        self.inRange = inRange
    }

    private func show(_ event: DownEvent) {
        switch event {
        case .checking(let friends): state += " (checking \(friends))"
        case .matched(let match): state = "Matched (\(match.bothDown ? "both down" : "a maybe"))"
        case .ended(let reason): state = "Not down (\(reason.rawValue))"
        }
    }
}

/// Asks for consent on every send; the re-check after consent can return a
/// different disclosure to exercise `OutboxError.policyChangedDuringConsent`.
actor DemoPolicy: PolicyEngine {
    private let first: Disclosure
    private let recheck: Disclosure
    private var evaluations = 0

    init(first: Disclosure, recheck: Disclosure) {
        self.first = first
        self.recheck = recheck
    }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        evaluations += 1
        return .needsConsent(evaluations == 1 ? first : recheck)
    }
}

/// Fakes-backed models for SwiftUI previews.
@MainActor
enum PreviewSupport {
    static func app(friends: [String] = ["Maya", "Sam"], scriptedModel: Bool = true) -> AppModel {
        let harness = DebugHarness(peers: friends.map { DebugHarness.randomPeer(nickname: $0) })
        var services = harness.services(rules: InMemoryRulesStore(), notifier: SilentNotifier())
        services.agent = DebugHarness.scriptedModel()
        services.localNetwork = SilentPrompter()
        return AppModel(services: services)
    }

    struct SilentNotifier: MatchNotifier {
        func requestAuthorization() async -> Bool { true }
        func post(_ notice: MatchNotice) async {}
    }

    struct SilentPrompter: LocalNetworkPrompter {
        func prompt() async {}
    }
}
#endif
