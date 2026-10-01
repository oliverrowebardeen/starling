#if DEBUG
// Debug builds only. StarlingFakes includes the insecure PSI stub and
// scripted doubles, so nothing outside `#if DEBUG` may import it (ADR 0140).
import Foundation
import StarlingAgent
import StarlingCore
import StarlingFakes
import StarlingFeatures

/// The Debug composition: real model, real rules file, fakes for everything
/// lanes E1, E2, and F have not delivered yet. The Developer screen drives
/// the fakes to walk the whole journey on one phone or the Simulator.
@MainActor
final class DebugHarness {
    static let scriptedModelKey = "dev.scriptedModel"

    let down = ScriptedDownService()
    let peers: InMemoryPairedPeerStore
    let usesScriptedModel: Bool
    /// Stands in for the secure channel until lanes E1 and E2 merge: frames
    /// injected here go through a real `Inbox` to the app's Inbox loop, and
    /// sends from the Outbox demos are recorded, not delivered.
    let transport = RecordingTransport()
    /// Created once: the transport's event stream has a single consumer.
    let inboxEvents: AsyncStream<InboxEvent>
    /// Fixed per launch so a repeated demo send has an identical disclosure
    /// and the consent memory can be seen.
    let sampleStart: Date
    private var pairingCount = 0

    init(peers: [PairedPeer] = [], defaults: UserDefaults = .standard) {
        self.peers = InMemoryPairedPeerStore(peers)
        usesScriptedModel = defaults.bool(forKey: Self.scriptedModelKey)
        inboxEvents = Inbox(localPeer: transport.localPeer).events(from: transport)
        sampleStart = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.up) * 3600)
    }

    func services(rules: any RulesStore = LiveServices.rulesStore(), notifier: any MatchNotifier = UserNotificationsNotifier.shared) -> AppServices {
        let down = down
        return AppServices(
            agent: usesScriptedModel ? Self.scriptedModel() : FoundationModelsAgent(),
            rules: rules,
            peers: peers,
            makeDownService: { _ in down },
            makePairingSession: { await DebugHarness.scriptedPairing() },
            inboxEvents: inboxEvents,
            makePolicy: LiveServices.policy(peers: peers),
            auditLog: LiveServices.auditLog,
            transport: transport,
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
        })
    }

    // MARK: Simulation (Developer screen)

    func addSampleFriend() async {
        pairingCount += 1
        try? await peers.save(Self.randomPeer(nickname: ["Maya", "Sam", "Jordan", "Priya", "Alex"][(pairingCount - 1) % 5]))
    }

    func simulateChecking() async {
        down.emit(.checking(friends: (try? await peers.all().count) ?? 0))
    }

    /// Emits a match with the first paired friend, as lane F will after both
    /// agents accept.
    func simulateMatch(bothDown: Bool) async -> Bool {
        guard let friend = try? await peers.all().first else { return false }
        let terms = (try? Self.sampleTerms()) ?? .empty
        down.emit(.matched(DownMatch(peer: friend.id, terms: terms, bothDown: bothDown)))
        return true
    }

    func simulateEnded(_ reason: DownEndReason) {
        down.emit(.ended(reason))
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
            return "Sent to \(friend.nickname) (recorded, not delivered)."
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
            return "Sent to \(friend.nickname) (recorded, not delivered)."
        } catch {
            return SendFailureMessage.text(for: error) ?? "Failed: \(error)"
        }
    }

    /// Injects a proposal from the first friend as if it arrived over the
    /// link, then reports how many Inbox events the Down service has seen.
    func simulateInboundMessage() async -> String {
        guard let friend = try? await peers.all().first else { return "Add a friend first." }
        do {
            let envelope = try Envelope(
                conversation: ConversationID(), sender: friend.id, recipient: transport.localPeer, sequence: 0,
                sentAt: Timestamp(Date()), body: .propose(try Proposal(round: 0, terms: Self.sampleTerms()))
            )
            transport.inject(.received(try Frame(EnvelopeCodec().encode(envelope)), from: friend.id))
        } catch {
            return "Couldn't build the message: \(error)"
        }
        try? await Task.sleep(for: .milliseconds(200))
        return "The Down service has received \(await down.handled.count) Inbox events."
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
