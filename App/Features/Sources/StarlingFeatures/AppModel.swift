import Foundation
import Observation
import StarlingCore

/// Everything the app's features are built from. The app target assembles
/// one for Debug (fakes from StarlingFakes) and one for Release (only real
/// implementations). A nil service means that feature is not in this build
/// yet, and its screen says so instead of pretending.
public struct AppServices: Sendable {
    public var agent: (any AgentModel)?
    public var rules: any RulesStore
    public var peers: (any PairedPeerStore)?
    /// Lane F's service. Takes the consent provider because its `Outbox`
    /// needs one, and the consent sheet belongs to the app.
    public var makeDownService: (@Sendable (any ConsentProvider) -> any DownService)?
    /// Lanes E1 and E2's pairing ceremony.
    public var makePairingSession: PairingSessionFactory?
    /// The app's one `Inbox` stream (v1.1: `Inbox.events(from:)` over the
    /// secure channel). `AppModel` is its single consumer and routes every
    /// event to the features; nil until a transport is in the build.
    public var inboxEvents: AsyncStream<InboxEvent>?
    public var notifier: any MatchNotifier
    public var localNetwork: any LocalNetworkPrompter
    /// Whether the PSI provider behind Down hides the owner's set. False
    /// while `InsecurePSIStub` is in use; the consent sheet says so.
    public var psiIsPrivate: Bool
    public var timeZone: TimeZone
    public var formatter: ValueFormatter

    public init(
        agent: (any AgentModel)?,
        rules: any RulesStore,
        peers: (any PairedPeerStore)?,
        makeDownService: (@Sendable (any ConsentProvider) -> any DownService)?,
        makePairingSession: PairingSessionFactory?,
        inboxEvents: AsyncStream<InboxEvent>? = nil,
        notifier: any MatchNotifier,
        localNetwork: any LocalNetworkPrompter,
        psiIsPrivate: Bool = false,
        timeZone: TimeZone = .current,
        formatter: ValueFormatter = ValueFormatter()
    ) {
        self.agent = agent
        self.rules = rules
        self.peers = peers
        self.makeDownService = makeDownService
        self.makePairingSession = makePairingSession
        self.inboxEvents = inboxEvents
        self.notifier = notifier
        self.localNetwork = localNetwork
        self.psiIsPrivate = psiIsPrivate
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
    private let downService: (any DownService)?
    private var inboxLoop: Task<Void, Never>?
    private var started = false

    public init(services: AppServices) {
        self.services = services
        consent = ConsentCoordinator(peers: services.peers, formatter: services.formatter)
        rulesEditor = RulesEditorModel(
            interpreter: RulesInterpreter(agent: services.agent, issues: RulesInterpreter.standingIssues, timeZone: services.timeZone),
            store: services.rules,
            formatter: services.formatter
        )
        if let makeDown = services.makeDownService, let peers = services.peers {
            let consent = consent
            let service = makeDown(consent)
            downService = service
            down = DownModel(
                service: service,
                interpreter: RulesInterpreter(agent: services.agent, issues: RulesInterpreter.intentIssues, timeZone: services.timeZone),
                rules: services.rules,
                peers: peers,
                notifier: services.notifier,
                formatter: services.formatter,
                timeZone: services.timeZone,
                intentChanged: { consent.forgetApprovals() }
            )
        } else {
            downService = nil
            down = nil
        }
        friends = services.peers.map(FriendsModel.init(store:))
    }

    /// Called once at launch.
    public func start() async {
        guard !started else { return }
        started = true
        down?.listen()
        routeInbox()
        await rulesEditor.load()
        await friends?.load()
    }

    /// The single Inbox loop: every event goes to the Down service, in
    /// arrival order, which ignores what is not part of Down. In Phase 1
    /// every conversation is Down's (F request 4); later features get their
    /// events here too.
    private func routeInbox() {
        guard inboxLoop == nil, let events = services.inboxEvents, let downService else { return }
        inboxLoop = Task {
            for await event in events {
                await downService.handle(event)
            }
        }
    }

    public func makeOnboarding() -> OnboardingModel {
        OnboardingModel(localNetwork: services.localNetwork, notifier: services.notifier)
    }

    /// A fresh ceremony model, or nil if pairing is not in this build.
    public func makePairing() -> PairingModel? {
        guard let factory = services.makePairingSession, let peers = services.peers else { return nil }
        return PairingModel(makeSession: factory, store: peers)
    }
}
