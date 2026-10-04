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
    /// The owner's live choices, for skill services built in `makeSkills`.
    /// `AppModel` attaches itself; nil when no service needs them.
    public var choices: OwnerChoices?
    /// The plans on this phone by origin, for skill services built in
    /// `makeSkills`. `AppModel` attaches its coordinator.
    public var plans: StandingPlans?
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
        choices: OwnerChoices? = nil,
        plans: StandingPlans? = nil,
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
        self.choices = choices
        self.plans = plans
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
    /// What iOS says about notifications, read at launch and on returning
    /// to the app. You shows a quiet line when it is `.denied` (ADR 0260).
    public private(set) var notificationAccess: NotificationAccess?
    /// Lane E's recorder of what each send disclosed (the Outbox's observer).
    public let egress: EgressRecorder
    /// This launch's sends not yet durably recorded, read live by every
    /// audit surface.
    public let pendingEgress = PendingEgress()
    /// Conversations whose egress log may be missing a send, from the
    /// recorder, and whether its journal could not be read at launch. Plan
    /// detail then claims nothing stayed on the phone there.
    public private(set) var unconfirmedConversations: Set<ConversationID> = []
    public private(set) var egressJournalUnreadable = false
    /// Whether this launch's journal recovery has finished. Until it has,
    /// every audit reads as incomplete: a send the journal alone holds is
    /// not on its interaction yet.
    public private(set) var egressRecovered = false
    /// Set when the conversation ledger cannot be read: Outbox then sends
    /// nothing at all, and Home says why.
    public private(set) var ledgerNotice: String?
    /// An interaction that just became a plan, for the It's a plan screen.
    public var celebrating: InteractionID?
    public let proposals: ProposalTexts

    private var inboxLoop: Task<Void, Never>?
    /// Lane E's after-plan-ends scheduler, running while the app is open.
    private var scheduler: PlanEndScheduler?
    private var schedulerLoop: Task<Void, Never>?
    private var startup: Task<Void, Never>?
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
        let relay = EgressRelay(pending: pendingEgress)
        let egress = EgressRecorder(sink: relay, journal: services.egressJournal)
        self.egress = egress
        let outbox: Outbox? = if let policy, let transport = services.transport {
            Outbox(
                transport: transport,
                // Every envelope of an owner's chain link must name its parent
                // (ADR 0240); the owner's topics still decide everything else.
                policy: ChainedFromPolicy(wrapping: policy, store: services.interactions),
                consent: consent,
                observer: FanOutObserver([egress, PendingEgressObserver(pending: pendingEgress)] + (services.auditLog.map { [$0] } ?? [])),
                sequences: services.sequences,
                ledger: services.ledger
            )
        } else {
            nil
        }
        self.outbox = outbox
        lifecycle = LifecycleCoordinator(
            registry: services.registry,
            // A skill behind a flag that is off runs no service, so nothing a
            // friend sends can reach it (Swap photos in Phase 1.5).
            services: outbox.map { services.makeSkills($0).filter { services.flags.enabled.contains($0.descriptor.id) } } ?? [],
            store: services.interactions
        )
        relay.lifecycle = lifecycle
        if let outbox { lifecycle.retire = { conversation in try await outbox.retire(conversation) } }
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

        services.choices?.attach(self)
        services.plans?.attach(lifecycle)
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
        // Interactions load, then the journal is recovered, and only then do
        // the services restore (privacy review of PR #73).
        lifecycle.beforeRestore = { [weak self] in await self?.recoverEgress() }
        let notes = notes
        lifecycle.onPassedChange = { notes.setPassed($0) }
        lifecycle.onRequestGroupsChange = { notes.setRequestGroups($0) }
        lifecycle.onChange = { [weak self] before, after in
            if after.state == .planned, before?.state != .planned, words.isVisible(after) { self?.celebrating = after.id }
            self?.updateParent(of: after)
            // A friend's request just installed: write any send its skill
            // made before the coordinator saw it (lane E's recorder).
            if before == nil, let egress = self?.egress {
                let conversation = after.conversation
                Task { await egress.interactionArrived(conversation: conversation) }
            }
            // A card the owner passed stays quiet until its skill ends it.
            if self?.lifecycle.passed.contains(after.id) == true { return }
            guard let notice = LifecycleNotice.make(before: before, after: after, words: words) else { return }
            Task { await notifier.post(notice) }
        }
    }

    /// Friends' names for words and notifications, kept in step with Friends.
    private let nameBox: NameBox

    public var home: HomeContent {
        syncNames()
        // A passed card is gone from this phone at once (ADR 0011 amendment 16).
        let passed = lifecycle.passed
        return HomeContent(lifecycle.interactions.filter { !passed.contains($0.id) }, words: words, groups: lifecycle.requestGroups)
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
    /// Every caller waits for the same startup.
    public func start() async {
        if startup == nil { startup = Task { await self.runStartup() } }
        await startup?.value
    }

    private func runStartup() async {
        // Rules and settings first: the policy denies every send until both
        // are loaded.
        await rulesEditor.load()
        await settings.load(phaseOneSharing: rulesEditor.saved?.rules.disclosure ?? [])
        await refreshPolicy()
        await friends?.load()
        syncNames()
        cards.load()
        notes.load()
        lifecycle.restorePassed(notes.passed)
        lifecycle.restoreRequestGroups(notes.requestGroups)
        refreshCard()
        // Recovers the egress journal between loading and restoring.
        await lifecycle.start()
        lifecycle.tick()
        await retryRetirements()
        startScheduler()
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
        if settings.settings.localNetworkAsked { await bringUpLinks() }
        // Reading the state asks nothing (ADR 0013).
        await refreshNotificationAccess()
    }

    /// Starts the radios and then whatever must follow them (lane E1's
    /// pairing services). Runs once.
    public func startLinks() async {
        await start()
        await bringUpLinks()
    }

    /// Startup's own step, which must not wait for startup to finish.
    private func bringUpLinks() async {
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

    /// Reads what iOS says about notifications now.
    public func refreshNotificationAccess() async {
        notificationAccess = await services.notifier.access()
    }

    /// After a pairing, Starling's one-button explanation leads straight
    /// to iOS's alert (ADR 0013 decision 3). Asked here, after the first
    /// friend, instead of after the first request (ADR 0260 amends ADR
    /// 0202 decision 3), and recorded so the request-time offer never
    /// asks again.
    public func askNotificationsAfterPairing() async {
        await settings.markNotificationsOffered()
        composer.offerNotifications = false
        notificationsAllowed = await services.notifier.requestAuthorization()
        await refreshNotificationAccess()
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
        inboxLoop = Task { [weak self] in
            for await event in events {
                // A friend paired a moment ago may say hello before the list
                // shows them: read the list again so their card is kept
                // (device test 2, issue #95).
                await self?.reloadFriendsIfNew(event)
                friends?.handle(event)
                await link?.handle(event)
                await lifecycle.route(event)
                // Compose sees a friend's new card only once every skill has
                // the same hello, so nothing it offers can start from an
                // older card (issue #123).
                cards.handle(event)
            }
        }
    }

    /// When the last unknown peer made the friends list reload; at most
    /// once every 2 seconds, so a stranger cannot make it reload all the time.
    private var lastFriendsReload: Date?

    private func reloadFriendsIfNew(_ event: InboxEvent) async {
        guard let friends else { return }
        let peer: PeerID
        switch event {
        case .peerAvailable(let id): peer = id
        case .message(let envelope): peer = envelope.sender
        default: return
        }
        guard !friends.friends.contains(where: { $0.id == peer }) else { return }
        let now = Date()
        if let last = lastFriendsReload, now.timeIntervalSince(last) < 2 { return }
        lastFriendsReload = now
        await friends.load()
        syncNames()
    }

    /// A chained Pick a place that agreed on a place moves its parent's plan
    /// there (lane E's `ChainPlanner.parent(_:updatedBy:)`, P15-E 4.6).
    private func updateParent(of link: Interaction) {
        guard let me = localPeer, let parentID = link.chain?.parent, let parent = lifecycle.interaction(parentID),
              let updated = ChainPlanner(registry: services.registry, me: me).parent(parent, updatedBy: link)
        else { return }
        lifecycle.update(updated)
    }

    /// Reads the recorder's view of which egress logs may be incomplete, and
    /// retries any record still waiting. Plan detail calls it when it opens.
    /// Brings back sends the journal still holds, so their conversations
    /// read as unconfirmed, and records them (P15-E 4.1). Runs inside the
    /// coordinator's startup, before any service restores.
    private func recoverEgress() async {
        await egress.recover()
        await refreshAudit()
        egressRecovered = true
    }

    /// The conversations whose audit may be missing a send right now: each
    /// pending send's own, and that of the interaction it named, which a
    /// Down for... member's send in the starter's conversation belongs to.
    var pendingAuditConversations: Set<ConversationID> {
        var result = Set<ConversationID>()
        for send in pendingEgress.messages.values {
            result.insert(send.conversation)
            if let id = send.interaction, let owner = lifecycle.owner(interaction: id, skill: send.skill, conversation: send.conversation) {
                result.insert(owner.conversation)
            }
        }
        return result
    }

    public func refreshAudit() async {
        await egress.retryPending()
        unconfirmedConversations = await egress.unconfirmedConversations
        egressJournalUnreadable = await egress.journalUnreadable
    }

    /// Ends plans whose time has passed and checks what is due after one;
    /// the app calls it when it comes to the foreground.
    public func foreground() {
        lifecycle.tick()
        Task { await refreshNotificationAccess() }
        Task {
            await retryRetirements()
            if let due = try? await scheduler?.due() { await handleScheduled(due) }
        }
    }

    private func retryRetirements() async {
        for case let service as any RetriesRetirements in lifecycle.allServices { await service.retryRetirements() }
    }

    /// Runs lane E's PlanEndScheduler while the app is open (P15-E 4.5): an
    /// after-plan-ends link the owner opted into starts when its plan ends.
    private func startScheduler() {
        guard schedulerLoop == nil, let me = localPeer else { return }
        let settings = settings
        let cards = cards
        let scheduler = PlanEndScheduler(
            schedule: PlanEndSchedule(planner: ChainPlanner(registry: services.registry, me: me)),
            store: services.interactions,
            settings: { await MainActor.run { settings.skillSettings } },
            cards: { await MainActor.run { cards.cards } }
        )
        self.scheduler = scheduler
        let handle: @Sendable ([ScheduledChain]) async -> Void = { [weak self] results in await self?.handleScheduled(results) }
        schedulerLoop = Task { await scheduler.run(handle) }
    }

    func handleScheduled(_ results: [ScheduledChain]) async {
        // A link that starts after the plan carries the owner's standing
        // rules, and stays out for a day.
        let expires = Timestamp(Date().addingTimeInterval(24 * 3600))
        for result in results { await lifecycle.applyScheduled(result, rules: standingRules, expiresAt: expires) }
    }

    /// Tears down the skills and the link.
    public func shutdown() async {
        inboxLoop?.cancel()
        inboxLoop = nil
        schedulerLoop?.cancel()
        schedulerLoop = nil
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
        let offer = NotificationOffer(
            shouldOffer: { [weak self] in
                guard let self else { return false }
                await self.refreshNotificationAccess()
                return self.notificationAccess == .notAsked
            },
            ask: { [weak self] in await self?.askNotificationsAfterPairing() }
        )
        return PairingModel(directory: directory, friends: { friends?.friends ?? [] }, notifications: offer)
    }

    /// Plan detail for a planned or finished interaction.
    public func planDetail(_ root: Interaction) -> PlanDetail {
        syncNames()
        return PlanDetail(root: root, all: lifecycle.interactions, words: words, notes: notes,
                          unconfirmed: unconfirmedConversations.union(pendingAuditConversations), auditUnknown: egressJournalUnreadable || !egressRecovered)
    }

    /// "Keep it going" after a plan: lane E's rows (P15-E request 4.4),
    /// only skills that accept what the plan produced, can run now, are in
    /// the build, and every friend in it supports. A friend whose card is
    /// not here hides the row. Rows that wait for the plan to end appear
    /// only while their skill's flag is on.
    public func chainSuggestions(after plan: Interaction) -> [ChainSuggestion] {
        guard let me = localPeer else { return [] }
        let inBuild = lifecycle.skillsInBuild
        return ChainPlanner(registry: services.registry, me: me)
            .suggestions(after: plan.id, in: lifecycle.interactions, settings: settings.skillSettings, cards: cards.cards)
            .filter { inBuild.contains($0.id) && settings.flags.enabled.contains($0.id) && $0.trigger == .atConfirm }
    }
}

/// Lets the egress recorder reach the lifecycle coordinator, which is built
/// after the Outbox. Before it is set (never, after init), nothing is
/// attributed.
@MainActor
private final class EgressRelay: EgressSink {
    weak var lifecycle: LifecycleCoordinator?
    let pending: PendingEgress

    init(pending: PendingEgress) { self.pending = pending }

    /// Clears the send from `pending` only once its record is durably on
    /// its interaction. A skill's send whose interaction is not installed
    /// yet (a friend's request answered right after the service announced
    /// it) returns false and stays pending: lane E's recorder keeps it
    /// journaled and writes it when `interactionArrived` is called. Only a
    /// link-level send, which no interaction owns, is cleared unattributed.
    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        try await appendEgress(record, conversation: conversation, interaction: nil)
    }

    /// The record goes to the interaction the send named (P15-B request 8):
    /// the one lane E's recorder kept in its journal, which survives a
    /// crash, or else the one this launch's observer saw. A recovered entry
    /// carries no skill, so its interaction is trusted as named: this
    /// phone's recorder wrote it from its own service's OutboundContext,
    /// never from a peer.
    func appendEgress(_ record: EgressRecord, conversation: ConversationID, interaction journaled: InteractionID?) async throws -> Bool {
        guard let lifecycle else { return false }
        let named = record.message.flatMap { pending.messages[$0] }
        let id = journaled ?? named?.interaction
        let skill = named?.skill ?? journaled.flatMap { lifecycle.interaction($0)?.skill }
        let found = try await lifecycle.appendEgress(record, interaction: id, skill: skill, conversation: conversation)
        if let message = record.message, found || !pending.isSkillSend(message) { pending.recorded(message) }
        return found
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
