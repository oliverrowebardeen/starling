import Foundation
import Observation
import PickAPlace
import StarlingChaining
import StarlingCore

/// Everything the app's features are built from. The app target assembles
/// one for Debug (fakes from StarlingFakes for lanes not merged yet) and one
/// for Release (only real implementations). A nil service means that
/// feature is not in this build yet, and its screen says so instead of
/// pretending (ADR 0140).
public struct AppServices: Sendable {
    /// The model for turning rules text into rules (You, Rules).
    public var agent: (any AgentModel)?
    /// Routing, chips, and proposal sentences in New and Home (ADR 0016).
    public var skillModel: (any SkillModel)?
    public var registry: SkillRegistry
    public var flags: SkillFlags
    /// Each skill's service, built on the app's one `Outbox` so every send
    /// is judged the same way. Empty until a skill lane merges.
    public var makeSkills: @Sendable (Outbox) -> [any SkillService]
    public var interactions: any InteractionStore
    public var settings: any OwnerSettingsStore
    public var rules: any RulesStore
    public var peers: (any PairedPeerStore)?
    /// Lane E1's pairing over the app's links, or nil if pairing is not in
    /// this build.
    public var pairing: PairingDirectory?
    /// Unpairs a friend everywhere (lane E1's `PinAuthority.unpair`).
    public var unpair: @Sendable (PeerID) async throws -> Void
    /// Renames a friend, or nil when the build has no safe way to.
    public var rename: (@Sendable (PeerID, String) async throws -> Void)?
    /// The app's one `Inbox` stream. `AppModel` is its single consumer.
    public var inboxEvents: AsyncStream<InboxEvent>?
    /// Lane G's policy engine for a snapshot of the rules and the
    /// on-device-only choice. `AppModel` wraps it in a `RulesPolicy`.
    public var makePolicy: (@Sendable (OwnerRules, Bool) -> any PolicyEngine)?
    /// Lane G's audit log, called after every send.
    public var auditLog: (any OutboxObserver)?
    /// Remembers each conversation's highest sent sequence number across
    /// launches (Core v2.1). Nil keeps it in memory only.
    public var sequences: (any RetainingSentSequenceStore)?
    /// Pick a place's search (MapKit and Core Location in the app) and the
    /// candidates New stages for its service (P15-D request 2). Nil when
    /// Pick a place is not in the build.
    public var placeFinder: PlaceFinder?
    public var stagedPlaces: StagedCandidates?
    /// Lane E's journal of sends whose egress record is not yet confirmed,
    /// on disk in the app (ADR 0021 decision 4).
    public var egressJournal: any EgressJournal
    /// The phone's record of retired conversations and answered candidates,
    /// which Outbox enforces (ADR 0021). Nil only in tests and previews.
    public var ledger: (any ConversationLedger)?
    /// The link the app's `Outbox` sends on. Nil until a transport the app
    /// may send owner data over is in the build.
    public var transport: (any Transport)?
    /// Runs once the transport has started (lane E1's pairing services).
    public var afterStart: (@Sendable () async -> Void)?
    /// Where this agent's model runs, for its card. Nil means no card and
    /// no link layer.
    public var agentLocality: ModelLocality?
    /// Lane G's consent sheet content for a disclosure.
    public var presentConsent: (@Sendable (Disclosure) -> ConsentPresentation)?
    public var notifier: any PlanNotifier
    public var localNetwork: any LocalNetworkPrompter
    /// Access APIs for skill permissions, from the skill lanes.
    public var permissions: [any PermissionAccess]
    /// Where friends' cards and plan notes are kept, or nil for memory only.
    public var cardsFile: JSONFile?
    public var notesFile: JSONFile?
    public var timeZone: TimeZone
    public var formatter: ValueFormatter

    public init(
        agent: (any AgentModel)? = nil,
        skillModel: (any SkillModel)? = nil,
        registry: SkillRegistry,
        flags: SkillFlags = .phase1_5,
        makeSkills: @escaping @Sendable (Outbox) -> [any SkillService] = { _ in [] },
        interactions: any InteractionStore,
        settings: any OwnerSettingsStore,
        rules: any RulesStore,
        peers: (any PairedPeerStore)?,
        pairing: PairingDirectory? = nil,
        unpair: @escaping @Sendable (PeerID) async throws -> Void = { _ in },
        rename: (@Sendable (PeerID, String) async throws -> Void)? = nil,
        inboxEvents: AsyncStream<InboxEvent>? = nil,
        makePolicy: (@Sendable (OwnerRules, Bool) -> any PolicyEngine)? = nil,
        auditLog: (any OutboxObserver)? = nil,
        sequences: (any RetainingSentSequenceStore)? = nil,
        ledger: (any ConversationLedger)? = nil,
        egressJournal: any EgressJournal = InMemoryEgressJournal(),
        placeFinder: PlaceFinder? = nil,
        stagedPlaces: StagedCandidates? = nil,
        transport: (any Transport)? = nil,
        afterStart: (@Sendable () async -> Void)? = nil,
        agentLocality: ModelLocality? = nil,
        presentConsent: (@Sendable (Disclosure) -> ConsentPresentation)? = nil,
        notifier: any PlanNotifier,
        localNetwork: any LocalNetworkPrompter,
        permissions: [any PermissionAccess] = [],
        cardsFile: JSONFile? = nil,
        notesFile: JSONFile? = nil,
        timeZone: TimeZone = .current,
        formatter: ValueFormatter = ValueFormatter()
    ) {
        self.agent = agent
        self.skillModel = skillModel
        self.registry = registry
        self.flags = flags
        self.makeSkills = makeSkills
        self.interactions = interactions
        self.settings = settings
        self.rules = rules
        self.peers = peers
        self.pairing = pairing
        self.unpair = unpair
        self.rename = rename
        self.inboxEvents = inboxEvents
        self.makePolicy = makePolicy
        self.auditLog = auditLog
        self.sequences = sequences
        self.ledger = ledger
        self.egressJournal = egressJournal
        self.placeFinder = placeFinder
        self.stagedPlaces = stagedPlaces
        self.transport = transport
        self.afterStart = afterStart
        self.agentLocality = agentLocality
        self.presentConsent = presentConsent
        self.notifier = notifier
        self.localNetwork = localNetwork
        self.permissions = permissions
        self.cardsFile = cardsFile
        self.notesFile = notesFile
        self.timeZone = timeZone
        self.formatter = formatter
    }
}

/// Owns the features for the app's lifetime: Home, New, Friends, and You
/// over one lifecycle coordinator (ADRs 0011 and 0015).
@MainActor
@Observable
public final class AppModel {
    public let services: AppServices
    public let consent: ConsentCoordinator
    public let rulesEditor: RulesEditorModel
    public let settings: SettingsModel
    public let lifecycle: LifecycleCoordinator
    public let cards: PeerCards
    public let notes: PlanNotes
    public let permissions: PermissionGate
    public let composer: ComposerModel
    /// Nil until a paired-peer store is in the build.
    public let friends: FriendsModel?
    /// The app's link layer: greets peers with this agent's card and answers
    /// hellos. Nil without an Outbox and a card.
    public let link: LinkTestModel?
    /// The policy every app send is judged by.
    public let policy: RulesPolicy?
    /// The app's one `Outbox`: lane G's policy, the consent sheet, the audit
    /// log, and the egress log. Nil until a transport is in the build.
    public let outbox: Outbox?
    public let words: InteractionWords
    /// This phone's PeerID, when a transport is in the build.
    public let localPeer: PeerID?
    /// Whether the owner allowed notifications, once asked.
    public private(set) var notificationsAllowed: Bool?
    /// Lane E's recorder of what each send disclosed (the Outbox's observer).
    public let egress: EgressRecorder
    /// Conversations whose egress log may be missing a send, from the
    /// recorder, and whether its journal could not be read at launch. Plan
    /// detail then claims nothing stayed on the phone there.
    public private(set) var unconfirmedConversations: Set<ConversationID> = []
    public private(set) var egressJournalUnreadable = false
    /// Set when the conversation ledger cannot be read: Outbox then sends
    /// nothing at all, and Home says why.
    public private(set) var ledgerNotice: String?
    /// An interaction that just became a plan, for the It's a plan screen.
    public var celebrating: InteractionID?
    public let proposals: ProposalTexts

    private var inboxLoop: Task<Void, Never>?
    private var started = false
    private var linksStarted = false
    private var friendNames: [PeerID: String] = [:]

    public init(services: AppServices) {
        self.services = services
        let localPeer = services.transport?.localPeer
        self.localPeer = localPeer
        consent = ConsentCoordinator(peers: services.peers, localPeer: localPeer, formatter: services.formatter, present: services.presentConsent)
        policy = services.makePolicy.map(RulesPolicy.init(make:))
        settings = SettingsModel(store: services.settings, flags: services.flags)
        notes = PlanNotes(file: services.notesFile)
        permissions = PermissionGate(access: services.permissions)
        proposals = ProposalTexts(model: services.skillModel)
        rulesEditor = RulesEditorModel(
            interpreter: RulesInterpreter(agent: services.agent, issues: RulesInterpreter.standingIssues, timeZone: services.timeZone),
            store: services.rules,
            formatter: services.formatter
        )
        let friends = services.peers.map { FriendsModel(store: $0, unpair: services.unpair, rename: services.rename) }
        self.friends = friends
        cards = PeerCards(file: services.cardsFile) { peer in friends?.friends.contains { $0.id == peer } ?? false }

        // Lane E's recorder writes "What left your phone" through the
        // lifecycle coordinator, which does not exist yet; the relay is
        // pointed at it right after (P15-E request 4.1).
        let relay = EgressRelay()
        let egress = EgressRecorder(sink: relay, journal: services.egressJournal)
        self.egress = egress
        let outbox: Outbox? = if let policy, let transport = services.transport {
            Outbox(
                transport: transport,
                // Every envelope of an owner's chain link must name its parent
                // (ADR 0240); the owner's topics still decide everything else.
                policy: ChainedFromPolicy(wrapping: policy, store: services.interactions),
                consent: consent,
                observer: FanOutObserver([egress] + (services.auditLog.map { [$0] } ?? [])),
                sequences: services.sequences,
                ledger: services.ledger
            )
        } else {
            nil
        }
        self.outbox = outbox
        lifecycle = LifecycleCoordinator(
            registry: services.registry,
            services: outbox.map(services.makeSkills) ?? [],
            store: services.interactions
        )
        relay.lifecycle = lifecycle
        consent.tracker = lifecycle
        let consent = consent
        lifecycle.onFinished = { interaction, conversation in
            consent.invalidate(interaction: interaction, conversation: conversation)
            // Skills retire their conversations themselves (ADR 0021
            // decision 10); this also covers an ending the owner made, so
            // nothing is ever sent in it again.
            if let outbox { Task { try? await outbox.retire(conversation) } }
        }

        let names = NameBox()
        words = InteractionWords(registry: services.registry, localPeer: localPeer, formatter: services.formatter, names: { names.value })
        nameBox = names

        if let outbox, let locality = services.agentLocality {
            link = LinkTestModel(outbox: outbox, card: AgentCard.forBuild(skills: [], usesPSI: false, locality: locality), name: { peer in
                friends?.friends.first { $0.id == peer }?.nickname
            })
        } else {
            link = nil
        }

        let rulesEditor = rulesEditor
        composer = ComposerModel(
            skillModel: services.skillModel, lifecycle: lifecycle, settings: settings, cards: cards, permissions: permissions,
            friends: { friends?.friends ?? [] }, savedRules: { rulesEditor.saved?.rules }, localPeer: localPeer,
            formatter: services.formatter,
            places: services.placeFinder.flatMap { finder in services.stagedPlaces.map { PlacePicker(finder: finder, staging: $0) } }
        )
        composer.beforeFirstRequest = { [weak self] in await self?.ensureLocalNetwork() }

        rulesEditor.onSaved = { [weak self] in await self?.refreshPolicy() }
        settings.beforeSave = { [weak self] interim in
            guard let self else { return }
            let previous = settings.settings
            await refreshPolicy(using: interim)
            // A stricter policy is in place: nothing cleared under the
            // looser one may still leave from a queue (ADR 0021 amendment 12).
            if OwnerSettings.tightens(previous, to: interim) { await outbox?.cancelInFlight() }
        }
        settings.onChange = { [weak self] in
            guard let self else { return }
            await refreshPolicy()
            refreshCard()
        }
        let notifier = services.notifier
        let words = words
        lifecycle.onChange = { [weak self] before, after in
            if after.state == .planned, before?.state != .planned, words.isVisible(after) { self?.celebrating = after.id }
            guard let notice = LifecycleNotice.make(before: before, after: after, words: words) else { return }
            Task { await notifier.post(notice) }
        }
    }

    /// Friends' names for words and notifications, kept in step with Friends.
    private let nameBox: NameBox

    public var home: HomeContent {
        syncNames()
        return HomeContent(lifecycle.interactions, words: words)
    }

    /// The card this agent sends in each `hello`: where its model runs and
    /// the skills that are in the build and switched on.
    public var agentCard: AgentCard? {
        guard let locality = services.agentLocality else { return nil }
        let inBuild = lifecycle.skillsInBuild
        let skills = services.registry.advertised(in: settings.skillSettings).filter { inBuild.contains($0.id) }
        let usesPSI = skills.contains { services.registry.descriptor(for: $0.id)?.buildingBlock == .mutualReveal }
        return AgentCard.forBuild(skills: skills, usesPSI: usesPSI, locality: locality)
    }

    /// The rules sends are judged by: saved constraints, with the privacy
    /// topics as the only standing sharing (ADR 0014).
    public var standingRules: OwnerRules {
        StandingRules.standing(saved: rulesEditor.saved?.rules, privacy: settings.settings.privacy)
    }

    func refreshPolicy() async {
        await refreshPolicy(using: settings.settings)
    }

    /// Installs the policy for `owner`, which during a settings write is the
    /// stricter of the old and new settings.
    func refreshPolicy(using owner: OwnerSettings) async {
        guard let policy else { return }
        // Unreadable saved rules may hold limits the app cannot see, and
        // unreadable settings may hold a Never. Leave the policy denying
        // everything until the owner saves again.
        if rulesEditor.loadFailed || !settings.isLoaded { return }
        // Unreadable privacy settings may hold a Never: nothing goes out
        // until the owner resets them (review of PR #54, finding 2).
        if settings.loadFailed {
            await policy.block()
            return
        }
        await policy.update(StandingRules.standing(saved: rulesEditor.saved?.rules, privacy: owner.privacy), onlyOnDeviceAgents: owner.onlyOnDeviceAgents)
    }

    private func refreshCard() {
        guard let link, let card = agentCard, link.card != card else { return }
        link.card = card
        // Tell friends who are around now; others hear at the next hello.
        for peer in friends?.reachable ?? [] { Task { await link.ping(peer) } }
    }

    private func syncNames() {
        var names: [PeerID: String] = [:]
        for friend in friends?.friends ?? [] { names[friend.id] = friend.nickname }
        if names != nameBox.value { nameBox.value = names }
    }

    /// Called once at launch. Loads rules, settings, friends, and the
    /// interactions, restores every skill's live work, and listens to the
    /// Inbox. The radios start only once Local Network has been asked for
    /// (at the first Pair or request); before that nobody could reach this
    /// phone anyway, because nobody is paired.
    public func start() async {
        guard !started else { return }
        started = true
        // Rules and settings first: the policy denies every send until both
        // are loaded.
        await rulesEditor.load()
        await settings.load(phaseOneSharing: rulesEditor.saved?.rules.disclosure ?? [])
        await refreshPolicy()
        await friends?.load()
        syncNames()
        cards.load()
        notes.load()
        refreshCard()
        await lifecycle.start()
        lifecycle.tick()
        // Before any plan detail shows: bring back sends the journal still
        // holds, so their conversations read as unconfirmed (P15-E 4.1).
        await egress.recover()
        await refreshAudit()
        if let ledger = services.ledger {
            do {
                _ = try await ledger.isRetired(ConversationID())
            } catch {
                ledgerNotice = "Starling's record of finished plans couldn't be read, so it won't send anything. Restart Starling to try again."
            }
        }
        // Before anything is sent this launch: keep sequence numbers for
        // every conversation that can still resume, and drop the rest. Not
        // when the interactions could not be read, which would drop them all.
        if lifecycle.notice == nil { try? services.sequences?.retainOnly(lifecycle.resumableConversations) }
        // Listening before the radios start, so no peerAvailable is missed.
        routeInbox()
        if settings.settings.localNetworkAsked { await startLinks() }
    }

    /// Starts the radios and then whatever must follow them (lane E1's
    /// pairing services). Runs once.
    public func startLinks() async {
        await start()
        guard !linksStarted else { return }
        linksStarted = true
        try? await services.transport?.start()
        await services.afterStart?()
    }

    /// The first Pair or the first request: the deliberate Local Network
    /// prompt, then the radios (ADR 0013 decision 2, ADR 0202).
    public func ensureLocalNetwork() async {
        if !settings.settings.localNetworkAsked {
            await services.localNetwork.prompt()
            await settings.markLocalNetworkAsked()
        }
        await startLinks()
    }

    /// The owner's answer to "Want a heads-up when friends are up for it?",
    /// asked after their first request.
    public func answerNotifications(_ yes: Bool) async {
        composer.offerNotifications = false
        await settings.markNotificationsOffered()
        guard yes else { return }
        notificationsAllowed = await services.notifier.requestAuthorization()
    }

    /// The single Inbox loop: every event, in arrival order, goes to the
    /// friends list (reachability), friends' cards, the link layer (hello),
    /// and through the lifecycle coordinator to every skill service.
    private func routeInbox() {
        guard inboxLoop == nil, let events = services.inboxEvents else { return }
        let friends = friends
        let cards = cards
        let link = link
        let lifecycle = lifecycle
        inboxLoop = Task {
            for await event in events {
                friends?.handle(event)
                cards.handle(event)
                await link?.handle(event)
                await lifecycle.route(event)
            }
        }
    }

    /// Reads the recorder's view of which egress logs may be incomplete, and
    /// retries any record still waiting. Plan detail calls it when it opens.
    public func refreshAudit() async {
        await egress.retryPending()
        unconfirmedConversations = await egress.unconfirmedConversations
        egressJournalUnreadable = await egress.journalUnreadable
    }

    /// Ends plans whose time has passed; the app calls it when it comes to
    /// the foreground.
    public func foreground() {
        lifecycle.tick()
    }

    /// Tears down the skills and the link.
    public func shutdown() async {
        inboxLoop?.cancel()
        inboxLoop = nil
        await lifecycle.shutdown()
        await services.transport?.stop()
    }

    /// Unpairs a friend and forgets what Starling kept about them.
    public func unpair(_ friend: PeerID) async {
        await friends?.remove(friend)
        guard !(friends?.friends.contains { $0.id == friend } ?? false) else { return }
        cards.forget(friend)
        notes.unlink(friend)
        await settings.forget(friend)
    }

    /// A fresh ceremony model, or nil if pairing is not in this build.
    public func makePairing() -> PairingModel? {
        guard let directory = services.pairing, services.peers != nil else { return nil }
        let friends = friends
        return PairingModel(directory: directory, friends: { friends?.friends ?? [] })
    }

    /// Plan detail for a planned or finished interaction.
    public func planDetail(_ root: Interaction) -> PlanDetail {
        syncNames()
        return PlanDetail(root: root, all: lifecycle.interactions, words: words, notes: notes,
                          unconfirmed: unconfirmedConversations, journalUnreadable: egressJournalUnreadable)
    }

    /// "Keep it going" after a plan: skills that accept what it produced,
    /// can run now, are in the build, and every friend in it supports
    /// (`SkillRegistry.chainSuggestions`, ADR 0012). A friend with no card
    /// yet hides the suggestion, since support cannot be shown.
    public func chainSuggestions(after plan: Interaction) -> [SkillDescriptor] {
        let peers = (plan.plan?.attendees.peers ?? plan.participants).filter { $0 != localPeer }
        let peerCards = peers.compactMap(cards.card(for:))
        guard peerCards.count == peers.count else { return [] }
        let inBuild = lifecycle.skillsInBuild
        return services.registry.chainSuggestions(after: plan.skill.id, in: settings.skillSettings, peers: peerCards)
            .filter { inBuild.contains($0.id) && $0.chainTrigger == .atConfirm }
    }
}

/// Lets the egress recorder reach the lifecycle coordinator, which is built
/// after the Outbox. Before it is set (never, after init), nothing is
/// attributed.
@MainActor
private final class EgressRelay: EgressSink {
    weak var lifecycle: LifecycleCoordinator?

    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        guard let lifecycle else { return false }
        return try await lifecycle.appendEgress(record, conversation: conversation)
    }
}

/// Friends' names, readable from the `@Sendable` closures words use.
private final class NameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [PeerID: String] = [:]
    var value: [PeerID: String] {
        get { lock.withLock { names } }
        set { lock.withLock { names = newValue } }
    }
}
