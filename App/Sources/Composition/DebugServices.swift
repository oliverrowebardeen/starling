#if DEBUG
// Debug builds only. StarlingFakes includes the insecure PSI stub and
// scripted doubles, so nothing outside `#if DEBUG` may import it (ADR 0140).
import Foundation
import Observation
import StarlingAgent
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingIdentity
import StarlingNegotiation
import StarlingTransport

/// The Debug composition: the same lane E1 stack as Release (Keychain
/// identity, one PinAuthority, secure LocalP2P and Wi-Fi Aware links, real
/// pairing), plus lane F's Down with the insecure PSI stub, plus a simulated
/// friend on an in-process secure Loopback link so the whole Down journey
/// runs on one phone or the Simulator (ADR 0144, ADR 0145). Fakes stay where
/// no lane has delivered: the PSI stub, the scripted model, sample friends.
@MainActor
final class DebugHarness {
    static let scriptedModelKey = "dev.scriptedModel"

    let usesScriptedModel: Bool
    let hub = LoopbackHub()
    /// Friends that exist only in this Debug session (the simulated friend,
    /// sample friends). Never written to the Keychain.
    let overlay = InMemoryPairedPeerStore()
    /// Set once services() has loaded the identity.
    private(set) var simFriend: SimulatedFriend?
    private(set) var friends: (any PairedPeerStore)?
    private(set) var appTransport: (any Transport)?
    /// Fixed per launch so a repeated demo send has an identical disclosure
    /// and the consent memory can be seen.
    let sampleStart: Date
    private var pairingCount = 0

    init(defaults: UserDefaults = .standard) {
        usesScriptedModel = defaults.bool(forKey: Self.scriptedModelKey)
        sampleStart = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.up) * 3600)
    }

    /// The Debug app's services: lane E1's identity from the Keychain, then
    /// the same secure links as Release with the simulated friend's
    /// Loopback link added.
    func services(rules: any RulesStore = LiveServices.rulesStore(), notifier: any MatchNotifier = UserNotificationsNotifier.shared) async throws -> AppServices {
        let identity = try await KeychainIdentityKeyStore().loadOrCreate()
        let agent: any AgentModel = usesScriptedModel ? Self.scriptedModel() : FoundationModelsAgent()
        let card = LiveServices.agentCard(locality: agent.descriptor.locality)

        let me = try PairedPeer(publicKey: identity.publicKey, nickname: "This phone", pairedAt: Timestamp(Date()))
        let simFriend = SimulatedFriend(hub: hub, owner: me, card: card)
        try await overlay.save(simFriend.peer)
        let friends = OverlayPairedPeerStore(base: KeychainPairedPeerStore(), overlay: overlay)
        let loopback = LoopbackTransport(localPeer: identity.peerID, hub: hub)
        let links = SecureLinks.make(identity: identity, friends: friends, extraLinks: [("In-app sim", loopback)])
        self.simFriend = simFriend
        self.friends = friends
        appTransport = links.transport
        Task { await simFriend.start() }

        return AppServices(
            agent: agent,
            rules: rules,
            peers: friends,
            makeDownService: { outbox in
                // docs/requests/F.md, answers to lane H: the app's Outbox, and
                // the insecure PSI stub until Nightjar.
                DownNegotiator(localPeer: identity.peerID, outbox: outbox, pairedPeers: friends, model: agent, psi: InsecurePSIStub())
            },
            pairing: links.pairingDirectory,
            unpair: links.unpair,
            rename: nil,
            inboxEvents: links.inboxEvents,
            makePolicy: LiveServices.policy(peers: friends),
            auditLog: LiveServices.auditLog,
            transport: links.transport,
            afterStart: links.startPairing,
            agentCard: card,
            downMatchingIsPrivate: InsecurePSIStub().descriptor.isPrivate,
            describeDownError: LiveServices.describeDownError,
            presentConsent: LiveServices.presentConsent,
            notifier: notifier,
            localNetwork: BonjourLocalNetworkPrompter()
        )
    }

    /// Fakes only, built synchronously for SwiftUI previews: sample friends,
    /// a recording transport, a scripted Down service and pairing ceremony.
    static func previewServices(friends: [String]) -> AppServices {
        let peers = InMemoryPairedPeerStore(friends.map { randomPeer(nickname: $0) })
        let demo = randomPeer(nickname: "Demo phone")
        let agent = scriptedModel()
        return AppServices(
            agent: agent,
            rules: InMemoryRulesStore(),
            peers: peers,
            makeDownService: { _ in ScriptedDownService() },
            pairing: PairingDirectory(
                localPeer: .random(),
                candidates: { [PairingCandidate(peer: demo.id, link: "Preview")] },
                pair: { _, nickname in
                    ScriptedPairingSession(code: "482 913", peer: try PairedPeer(publicKey: demo.publicKey, nickname: nickname, pairedAt: Timestamp(Date())))
                },
                paired: { peer in try? await peers.save(peer) }
            ),
            unpair: { id in try await peers.remove(id) },
            makePolicy: LiveServices.policy(peers: peers),
            transport: RecordingTransport(),
            agentCard: LiveServices.agentCard(locality: .onDevice),
            presentConsent: LiveServices.presentConsent,
            notifier: PreviewSupport.SilentNotifier(),
            localNetwork: PreviewSupport.SilentPrompter()
        )
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

    /// A friend that is never reachable, kept in the in-memory overlay.
    func addSampleFriend() async {
        pairingCount += 1
        try? await overlay.save(Self.randomPeer(nickname: ["Maya", "Sam", "Jordan", "Priya", "Alex"][(pairingCount - 1) % 5]))
    }

    /// Sends a sample proposal to the simulated friend through the app's
    /// Outbox: lane G's policy, the consent sheet, and the audit log, over
    /// the secure Loopback link. Returns what happened in plain words.
    func sendSample(through outbox: Outbox?) async -> String {
        guard let outbox else { return "This build has no Outbox." }
        guard let friend = simFriend?.peer, let proposal = try? Proposal(round: 0, terms: Self.sampleTerms(start: sampleStart)) else {
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
        guard let transport = appTransport, let friend = simFriend?.peer,
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

/// A second phone in the same process, paired with this one: its own lane E1
/// identity and PinAuthority, a SecureTransport over an in-process Loopback
/// link, lane F's DownNegotiator, and the app's link layer for hellos. It
/// approves its own consent and allows every send, because only this
/// phone's side should exercise lane G's policy and the consent sheet.
@MainActor
@Observable
final class SimulatedFriend {
    let peer: PairedPeer
    private(set) var state = "Not down"
    private(set) var inRange = true
    private let ownerID: PeerID
    private let hub: LoopbackHub
    private let transport: SecureTransport
    private let outbox: Outbox
    private let negotiator: DownNegotiator
    private let link: LinkTestModel
    private var started = false

    init(hub: LoopbackHub, owner: PairedPeer, card: AgentCard) {
        let identity = IdentityKeyPair.generate()
        peer = try! PairedPeer(publicKey: identity.publicKey, nickname: "Sim friend", pairedAt: Timestamp(Date()))
        ownerID = owner.id
        self.hub = hub
        let pinned = InMemoryPairedPeerStore([owner])
        transport = SecureTransport(
            wrapping: LoopbackTransport(localPeer: identity.peerID, hub: hub),
            authority: PinAuthority(identity: identity, store: pinned)
        )
        outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
        negotiator = DownNegotiator(
            localPeer: identity.peerID,
            outbox: outbox,
            pairedPeers: pinned,
            model: ScriptedAgentModel(onDecide: { _ in .accept }),
            psi: InsecurePSIStub()
        )
        link = LinkTestModel(outbox: outbox, card: card, name: { _ in nil })
    }

    func start() async {
        guard !started else { return }
        started = true
        let events = Inbox(localPeer: peer.id).events(from: transport)
        let negotiator = negotiator
        let link = link
        Task {
            for await event in events {
                await link.handle(event)
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

/// Runs the whole Down journey headless when the app is launched with
/// `-starlingSelfTestDown YES`, and prints the outcome: the simulated friend
/// goes down, this phone goes down with overlapping time, every consent
/// sheet is approved, and the test waits for a match. Evidence that lane F's
/// DownNegotiator, lane G's policy, the consent sheet, and the app's Inbox
/// loop work together, where the Simulator cannot be tapped through.
@MainActor
enum DownSelfTest {
    static func runIfRequested(app: AppModel, harness: DebugHarness) async {
        guard UserDefaults.standard.bool(forKey: "starlingSelfTestDown"), let down = app.down, let sim = harness.simFriend else { return }
        await app.start()
        let approver = Task {
            while !Task.isCancelled {
                if let request = app.consent.current {
                    print("SELFTEST consent: \(request.items.map(\.title).joined(separator: ", ")) to \(request.recipientName)")
                    app.consent.answer(.approved, to: request.id)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { approver.cancel() }

        await sim.goDown(.down)
        print("SELFTEST sim friend: \(sim.state)")
        await down.editByHand()
        down.draft.add(.within, issue: .time)
        down.draft.add(.prefers, issue: .activity)
        down.draft.items[down.draft.items.count - 1].likedText = "food"
        down.draft.add(.atMost, issue: .budget)
        down.draft.items[down.draft.items.count - 1].amountMinorUnits = 1500
        down.level = .down
        down.duration = .threeHours
        await down.goDown()
        print("SELFTEST owner: phase \(down.phase), notice \(down.notice ?? "none")")

        for _ in 0..<600 where down.matches.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let match = down.matches.first {
            print("SELFTEST MATCH with \(match.friendName): \(match.lines.map { "\($0.title)=\($0.detail ?? "")" }.joined(separator: "; ")); bothDown \(match.bothDown); status \(down.status)")
        } else {
            print("SELFTEST NO MATCH after 60 s; status \(down.status); checking \(String(describing: down.active?.checkingFriends)); sim friend \(sim.state)")
        }
        let audited = await LiveServices.auditLog.entries()
        print("SELFTEST audit: \(audited.map { $0.kind.rawValue }.joined(separator: ","))")
    }
}

/// The Keychain friends plus friends that exist only in this Debug session
/// (the simulated friend, sample friends), which are never written to the
/// Keychain. Lane E1's authority commits real pairings to the Keychain part.
actor OverlayPairedPeerStore: PairedPeerStore {
    private let base: any PairedPeerStore
    private let overlay: InMemoryPairedPeerStore

    init(base: any PairedPeerStore, overlay: InMemoryPairedPeerStore) {
        self.base = base
        self.overlay = overlay
    }

    func all() async throws -> [PairedPeer] {
        let session = try await overlay.all()
        let ids = Set(session.map(\.id))
        return (try await base.all()).filter { !ids.contains($0.id) } + session
    }

    func peer(for id: PeerID) async throws -> PairedPeer? {
        if let peer = try await overlay.peer(for: id) { return peer }
        return try await base.peer(for: id)
    }

    func save(_ peer: PairedPeer) async throws {
        if try await overlay.peer(for: peer.id) != nil { try await overlay.save(peer) } else { try await base.save(peer) }
    }

    func remove(_ id: PeerID) async throws {
        if try await overlay.peer(for: id) != nil { try await overlay.remove(id) } else { try await base.remove(id) }
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
    static func app(friends: [String] = ["Maya", "Sam"]) -> AppModel {
        AppModel(services: DebugHarness.previewServices(friends: friends))
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
