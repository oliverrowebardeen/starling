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
    private var pairingCount = 0

    init(peers: [PairedPeer] = [], defaults: UserDefaults = .standard) {
        self.peers = InMemoryPairedPeerStore(peers)
        usesScriptedModel = defaults.bool(forKey: Self.scriptedModelKey)
    }

    func services(rules: any RulesStore = LiveServices.rulesStore(), notifier: any MatchNotifier = UserNotificationsNotifier.shared) -> AppServices {
        let down = down
        return AppServices(
            agent: usesScriptedModel ? Self.scriptedModel() : FoundationModelsAgent(),
            rules: rules,
            peers: peers,
            makeDownService: { _ in down },
            makePairingSession: { await DebugHarness.scriptedPairing() },
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

    /// Asks the consent sheet about a typical Down disclosure, the way
    /// `Outbox` will once lanes F and G merge.
    func requestSampleConsent(through consent: any ConsentProvider) async -> ConsentOutcome? {
        guard let friend = try? await peers.all().first, let disclosure = try? Self.sampleDisclosure(to: friend.id) else { return nil }
        return await consent.requestConsent(for: disclosure)
    }

    static func sampleTerms() throws -> Terms {
        let start = Date().addingTimeInterval(3600)
        return try Terms([
            .time: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(2 * 3600))]),
            .activity: .keywords([try Keyword("boba run")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
        ])
    }

    static func sampleDisclosure(to peer: PeerID) throws -> Disclosure {
        let start = Date().addingTimeInterval(3600)
        return Disclosure(recipient: peer, recipientModel: .onDevice, items: [
            DisclosedItem(category: .psi, issue: .time, value: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(4 * 3600))])),
            DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("food")])),
            DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: 1500))),
        ])
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
