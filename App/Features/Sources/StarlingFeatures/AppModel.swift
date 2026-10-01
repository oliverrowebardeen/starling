import Foundation
import Observation
import StarlingCore

/// A Down service that must be told when the app tears it down (lane F's
/// DownNegotiator: "Call shutdown() when tearing the service down").
public protocol StoppableDownService: DownService {
    func shutdown() async
}

/// Everything the app's features are built from. The app target assembles
/// one for Debug (fakes from StarlingFakes) and one for Release (only real
/// implementations). A nil service means that feature is not in this build
/// yet, and its screen says so instead of pretending.
public struct AppServices: Sendable {
    public var agent: (any AgentModel)?
    public var rules: any RulesStore
    public var peers: (any PairedPeerStore)?
    /// Lane F's service, built on the app's `Outbox` (lane G's policy, the
    /// consent sheet, the audit log) so every Down send is judged the same
    /// way. Its local peer must be the Outbox transport's.
    public var makeDownService: (@Sendable (Outbox) -> any DownService)?
    /// Lane E1's pairing over the app's links, or nil if pairing is not in
    /// this build.
    public var pairing: PairingDirectory?
    /// Unpairs a friend everywhere (lane E1's `PinAuthority.unpair`).
    public var unpair: @Sendable (PeerID) async throws -> Void
    /// Renames a friend, or nil when the build has no safe way to.
    public var rename: (@Sendable (PeerID, String) async throws -> Void)?
    /// The app's one `Inbox` stream (v1.1: `Inbox.events(from:)` over the
    /// secure channel). `AppModel` is its single consumer and routes every
    /// event to the features; nil until a transport is in the build.
    public var inboxEvents: AsyncStream<InboxEvent>?
    /// Builds lane G's policy engine for a snapshot of the owner's rules.
    /// `AppModel` wraps it in a `RulesPolicy` that follows rule changes.
    public var makePolicy: (@Sendable (OwnerRules) -> any PolicyEngine)?
    /// Lane G's audit log, installed as the Outbox observer.
    public var auditLog: (any OutboxObserver)?
    /// The link the app's `Outbox` sends on. Nil until a transport the app
    /// may send owner data over is in the build (lane E1's secure channel).
    public var transport: (any Transport)?
    /// This agent's card, sent in a `hello` to each peer that becomes
    /// available. Down reads peers' cards; it does not send its own.
    public var agentCard: AgentCard?
    /// Whether Down's PSI provider hides the owner's free times.
    public var downMatchingIsPrivate: Bool
    /// Plain words for the Down service's own errors.
    public var describeDownError: @Sendable (any Error) -> String?
    /// Lane G's consent sheet content for a disclosure.
    public var presentConsent: (@Sendable (Disclosure) -> ConsentPresentation)?
    public var notifier: any MatchNotifier
    public var localNetwork: any LocalNetworkPrompter
    public var timeZone: TimeZone
    public var formatter: ValueFormatter

    public init(
        agent: (any AgentModel)?,
        rules: any RulesStore,
        peers: (any PairedPeerStore)?,
        makeDownService: (@Sendable (Outbox) -> any DownService)?,
        pairing: PairingDirectory?,
        unpair: @escaping @Sendable (PeerID) async throws -> Void = { _ in },
        rename: (@Sendable (PeerID, String) async throws -> Void)? = nil,
        inboxEvents: AsyncStream<InboxEvent>? = nil,
        makePolicy: (@Sendable (OwnerRules) -> any PolicyEngine)? = nil,
        auditLog: (any OutboxObserver)? = nil,
        transport: (any Transport)? = nil,
        agentCard: AgentCard? = nil,
        downMatchingIsPrivate: Bool = false,
        describeDownError: @escaping @Sendable (any Error) -> String? = { _ in nil },
        presentConsent: (@Sendable (Disclosure) -> ConsentPresentation)? = nil,
        notifier: any MatchNotifier,
        localNetwork: any LocalNetworkPrompter,
        timeZone: TimeZone = .current,
        formatter: ValueFormatter = ValueFormatter()
    ) {
        self.agent = agent
        self.rules = rules
        self.peers = peers
        self.makeDownService = makeDownService
        self.pairing = pairing
        self.unpair = unpair
        self.rename = rename
        self.inboxEvents = inboxEvents
        self.makePolicy = makePolicy
        self.auditLog = auditLog
        self.transport = transport
        self.agentCard = agentCard
        self.downMatchingIsPrivate = downMatchingIsPrivate
        self.describeDownError = describeDownError
        self.presentConsent = presentConsent
        self.notifier = notifier
        self.localNetwork = localNetwork
        self.timeZone = timeZone
        self.formatter = formatter
    }
}

/// Owns the feature models for the app's lifetime.
@MainActor
@Observable
public final class AppModel {
    public let services: AppServices
    public let consent: ConsentCoordinator
    public let rulesEditor: RulesEditorModel
    /// Nil until a `DownService` and a paired-peer store are in the build.
    public let down: DownModel?
    public let friends: FriendsModel?
    /// The policy every app send is judged by, following the owner's rules.
    public let policy: RulesPolicy?
    /// The app's one `Outbox`: lane G's policy, the consent sheet, and the
    /// audit log. Nil until a transport is in the build.
    public let outbox: Outbox?
    private let downService: (any DownService)?
    private var inboxLoop: Task<Void, Never>?
    private var started = false

    public init(services: AppServices) {
        self.services = services
        consent = ConsentCoordinator(peers: services.peers, formatter: services.formatter, present: services.presentConsent)
        policy = services.makePolicy.map(RulesPolicy.init(make:))
        if let policy, let transport = services.transport {
            outbox = Outbox(transport: transport, policy: policy, consent: consent, observer: services.auditLog)
        } else {
            outbox = nil
        }
        rulesEditor = RulesEditorModel(
            interpreter: RulesInterpreter(agent: services.agent, issues: RulesInterpreter.standingIssues, timeZone: services.timeZone),
            store: services.rules,
            formatter: services.formatter
        )
        if let makeDown = services.makeDownService, let peers = services.peers, let outbox {
            let service = makeDown(outbox)
            downService = service
            down = DownModel(
                service: service,
                interpreter: RulesInterpreter(agent: services.agent, issues: RulesInterpreter.intentIssues, timeZone: services.timeZone),
                rules: services.rules,
                peers: peers,
                notifier: services.notifier,
                matchingIsPrivate: services.downMatchingIsPrivate,
                describeError: services.describeDownError,
                formatter: services.formatter,
                timeZone: services.timeZone
            )
        } else {
            downService = nil
            down = nil
        }
        friends = services.peers.map { FriendsModel(store: $0, unpair: services.unpair, rename: services.rename) }
        rulesEditor.onSaved = { [weak self] in await self?.refreshPolicy() }
        down?.intentChanged = { [weak self] in
            guard let self else { return }
            consent.forgetApprovals()
            await refreshPolicy()
        }
    }

    /// The rules sends are judged by: the saved rules, merged with the
    /// active Down intent's rules when one is out (most restrictive sharing
    /// wins, ADR 0141). Nil when they cannot be combined: the saved rules
    /// changed after the intent went out and the constraints together break
    /// a limit. Never falls back to the saved rules alone, which would drop
    /// the intent's own "never share" rules.
    public var effectiveRules: OwnerRules? {
        let standing = rulesEditor.saved?.rules ?? .empty
        guard let intent = down?.activeIntentRules else { return standing }
        let sharing = RulesMerge.sharing(intent: intent.disclosure, standing: standing.disclosure)
        guard let constraints = try? RulesMerge.constraints(intent: intent.constraints, standing: standing.constraints) else { return nil }
        return OwnerRules(constraints: constraints, disclosure: sharing)
    }

    func refreshPolicy() async {
        guard let policy else { return }
        // Unreadable saved rules may hold "never share" rules the app cannot
        // see. Leave the policy denying everything until the owner saves.
        if rulesEditor.loadFailed { return }
        if let rules = effectiveRules {
            await policy.update(rules)
            return
        }
        // Fail closed: block every send first, then end the intent. Ending
        // it reports an intent change, which updates the policy again with
        // the saved rules once nothing can send for the intent any more.
        await policy.block()
        await down?.endBecauseRulesChanged()
    }

    /// Called once at launch.
    public func start() async {
        guard !started else { return }
        started = true
        // Rules first: the policy denies every send until it has them.
        await rulesEditor.load()
        await refreshPolicy()
        down?.listen()
        routeInbox()
        // After the loop is listening, so no peerAvailable is missed.
        try? await services.transport?.start()
        await friends?.load()
    }

    /// The single Inbox loop: every event goes to the Down service, in
    /// arrival order, which ignores what is not part of Down. In Phase 1
    /// every conversation is Down's (F request 4); later features get their
    /// events here too.
    private func routeInbox() {
        // Runs whenever there is an Inbox: Release has friends (and their
        // reachability) even without Down.
        guard inboxLoop == nil, let events = services.inboxEvents else { return }
        let downService = downService
        let outbox = outbox
        let card = services.agentCard
        let friends = friends
        inboxLoop = Task {
            for await event in events {
                // The link layer greets each peer with this agent's card, so
                // the peer's policy knows where the model runs. Hello is
                // always allowed and carries nothing else. Not awaited, so a
                // slow link never holds up the loop.
                if case .peerAvailable(let peer) = event, let outbox, let card {
                    Task { _ = try? await outbox.send(.hello(card), to: peer, conversation: ConversationID()) }
                }
                friends?.handle(event)
                await downService?.handle(event)
            }
        }
    }

    /// Tears down the Down service and the link. Call when the app's
    /// services go away; lane F requires shutdown() on its service.
    public func shutdown() async {
        inboxLoop?.cancel()
        inboxLoop = nil
        if let stoppable = downService as? any StoppableDownService { await stoppable.shutdown() }
        await services.transport?.stop()
    }

    public func makeOnboarding() -> OnboardingModel {
        OnboardingModel(localNetwork: services.localNetwork, notifier: services.notifier)
    }

    /// A fresh ceremony model, or nil if pairing is not in this build.
    public func makePairing() -> PairingModel? {
        guard let directory = services.pairing, services.peers != nil else { return nil }
        return PairingModel(directory: directory)
    }
}
