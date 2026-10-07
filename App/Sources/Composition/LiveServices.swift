import DownFor
import FindATime
import StarlingChangePlan
import Foundation
import Network
import PickAPlace
import PickAPlaceMapKit
import StarlingAgent
import StarlingAvailability
import StarlingChaining
import StarlingCore
import StarlingFeatures
import StarlingIdentity
import StarlingPolicy
import StarlingSwapPhotos
import StarlingWiFiAware
import UserNotifications

extension AppServices {
    /// Release builds: real implementations only, never StarlingFakes
    /// (ADR 0140). Lane E1's identity, pinned friends, pairing, and secure
    /// links; lane G's policy and audit log; lane E2's Wi-Fi Aware; Find a
    /// time, Pick a place, and Swap photos (behind its flag) from lanes C, D,
    /// and E. Down for... has no service: its only PSI provider is the
    /// insecure stub in StarlingFakes (ADR 0144 decision 3), so its tile says
    /// "Not in this build yet" instead of running on that stub.
    @MainActor
    static func release() async throws -> AppServices {
        let identity = try await KeychainIdentityKeyStore().loadOrCreate()
        // One on-device model for the rules editor, New, and proposal cards.
        let agent = FoundationModelsAgent()
        let links = SecureLinks.make(identity: identity, friends: KeychainPairedPeerStore())
        let ledger = LiveServices.ledger()
        let rules = LiveServices.rulesStore()
        let places = LiveServices.places()
        let interactions = LiveServices.interactionStore()
        let choices = OwnerChoices()
        // One change to a plan at a time (ADR 0023): every skill that
        // changes a plan shares these.
        let holds = PlanChangeHolds()
        let plans = StandingPlans()
        return AppServices(
            agent: agent,
            skillModel: agent,
            registry: LiveServices.registry,
            makeSkills: { outbox in
                [
                    LiveServices.findATime(me: identity.peerID, outbox: outbox, friends: links.friends, ledger: ledger, choices: choices),
                    LiveServices.pickAPlace(me: identity.peerID, outbox: outbox, friends: links.friends, staged: places.staged, rules: rules, ledger: ledger,
                                            plans: plans, holds: holds),
                    LiveServices.swapPhotos(me: identity.peerID, outbox: outbox, ledger: ledger, plans: plans),
                    LiveServices.changePlan(me: identity.peerID, outbox: outbox, ledger: ledger, plans: plans, holds: holds),
                ]
            },
            interactions: interactions,
            settings: LiveServices.settingsStore(),
            rules: rules,
            peers: links.friends,
            pairing: links.pairingDirectory,
            unpair: links.unpair,
            rename: links.rename,
            inboxEvents: links.inboxEvents,
            makePolicy: LiveServices.policy(peers: links.friends),
            auditLog: LiveServices.auditLog,
            sequences: try? FileSentSequenceStore.standard(),
            ledger: ledger,
            egressJournal: LiveServices.egressJournal(),
            placeFinder: places.finder,
            stagedPlaces: places.staged,
            choices: choices,
            plans: plans,
            changesInProgress: PlanChangesInProgress(holds),
            transport: links.transport,
            afterStart: links.startPairing,
            agentLocality: .onDevice,
            presentConsent: LiveServices.presentConsent,
            notifier: UserNotificationsNotifier.shared,
            localNetwork: BonjourLocalNetworkPrompter(),
            permissions: [LocationPermissionAccess(location: places.location), LiveServices.calendarPermission],
            cardsFile: try? .standard("peer-cards.json"),
            notesFile: try? .standard("plan-notes.json")
        )
    }
}

enum LiveServices {
    /// Every Phase 1.5 skill's descriptor, from each lane's package. Data
    /// only: a descriptor runs nothing without its service. Down for... has
    /// no service in Release, because its only PSI provider is the stub in
    /// StarlingFakes (ADR 0144 decision 3), so its tile says "Not in this
    /// build yet".
    static let registry: SkillRegistry = try! SkillRegistry([
        DownFor.descriptor,
        FindATimeSkill.descriptor,
        PickAPlaceSkill.descriptor,
        SwapPhotos.descriptor,
        ChangePlan.descriptor,
    ])

    /// The app's one EventKit store: the permission sheet asks through it,
    /// and Find a time reads busy times from it (P15-C request 1).
    static let calendar = EventKitCalendarStore()

    /// Lane C's calendar access, asked only from Starling's sheet.
    static var calendarPermission: CalendarPermissionAccess {
        CalendarPermissionAccess(access: CalendarAccess(store: calendar))
    }

    static func rulesStore() -> any RulesStore {
        (try? FileRulesStore.standard()) ?? InMemoryRulesStore()
    }

    static func interactionStore() -> any InteractionStore {
        (try? FileInteractionStore.standard())
            ?? FileInteractionStore(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "interactions.json")))
    }

    /// The phone's conversation ledger (ADR 0021). If its file cannot even
    /// be located, a ledger that refuses everything stands in, so Outbox
    /// sends nothing rather than sending without one.
    static func ledger() -> any ConversationLedger {
        (try? FileConversationLedger.standard()) ?? UnavailableConversationLedger()
    }

    /// Lane E's journal of unconfirmed sends, on disk (P15-E request 4.1).
    /// If its file cannot be located, a journal that refuses everything
    /// stands in, so no send leaves unrecorded.
    static func egressJournal() -> any EgressJournal {
        (try? FileEgressJournal.standard()) ?? UnavailableEgressJournal()
    }

    /// Pick a place's search pieces: one Core Location access shared by the
    /// finder and the permission gate, MapKit search, and the staging New
    /// fills before a request starts (P15-D requests 1 and 2).
    @MainActor
    static func places() -> (finder: PlaceFinder, staged: StagedCandidates, location: CoreLocationAccess) {
        let location = CoreLocationAccess()
        return (PlaceFinder(search: MapKitPlaceSearch(), location: location), StagedCandidates(), location)
    }

    /// Lane B's service over the app's one Outbox and the ledger it
    /// enforces, with its requests on disk and only paired friends'
    /// invitations shown (P15-B request 2). `psi` must be private before
    /// Release may call this (ADR 0144).
    static func downFor(me: PeerID, outbox: Outbox, agent: any AgentModel, psi: any PSIProvider, friends: any PairedPeerStore, ledger: any ConversationLedger) -> any SkillService {
        let store: any DownForRequestStore = (try? FileDownForRequestStore.standard()) ?? UnavailableDownForRequestStore()
        return DownForService(localPeer: me, outbox: outbox, model: agent, psi: psi, ledger: ledger, store: store, pairedPeers: friends)
    }

    /// Lane C's service over the app's one Outbox and the same conversation
    /// ledger the Outbox enforces (P15-C request 2). It reads busy times from
    /// the app's one calendar store, only while the owner uses it, and
    /// keeps its checkpoints in Application Support so a request survives a
    /// relaunch (ADR 0222).
    static func findATime(me: PeerID, outbox: Outbox, friends: any PairedPeerStore, ledger: any ConversationLedger, choices: OwnerChoices) -> any SkillService {
        FindATimeService(
            localPeer: me, outbox: outbox, conversations: ledger, pairedPeers: friends,
            availability: .standard(calendar: calendar, use: { await choices.calendarUse() }),
            checkpoints: FileFindATimeCheckpoints(directory: findATimeCheckpoints()),
            isTurnedOn: { await choices.isOn(.findATime) },
            standingRules: { await choices.standingConstraints() }
        )
    }

    /// `Application Support/Starling/FindATime`, or a temporary directory if
    /// that cannot be located, as for the interaction store.
    static func findATimeCheckpoints() -> URL {
        (try? JSONFile.standard("FindATime").url) ?? FileManager.default.temporaryDirectory.appending(path: "FindATime", directoryHint: .isDirectory)
    }

    /// Lane D's service over the app's one Outbox and the same conversation
    /// ledger the Outbox enforces (P15-D request 3). A friend checks a
    /// change of a plan's place against this phone's plan (ADR 0233, P15-D
    /// request 15), read from the coordinator's interactions in memory:
    /// the interaction store is written asynchronously and can lag them,
    /// or stay stale after a failed save, so a yes to change B could be
    /// checked against the plan from before change A (review of #118).
    static func pickAPlace(me: PeerID, outbox: Outbox, friends: any PairedPeerStore, staged: StagedCandidates,
                           rules: any RulesStore, ledger: any ConversationLedger, plans: StandingPlans,
                           holds: any PlanChangeHolding) -> any SkillService {
        PickAPlaceService(
            localPeer: me, outbox: outbox, pairedPeers: friends, candidates: staged, maps: MapKitPlaceSearch(),
            // The owner's standing budget, diet, and place limits, read when
            // a friend asks; the organizer's own come with its request.
            ownerLimits: { (try? await rules.load())?.rules.constraints ?? .empty },
            ledger: UserDefaultsPickAPlaceLedger(), conversations: ledger,
            plans: { conversation in await plans.plan(origin: conversation) },
            holds: holds
        )
    }

    /// Lane E's Swap photos over the app's one Outbox and the same
    /// conversation ledger it enforces (P15-E request 4.8). An offer is
    /// checked against the plan saved on this phone. Runs only while its
    /// flag is on (AppModel drops a flagged-off service).
    static func swapPhotos(me: PeerID, outbox: Outbox, ledger: any ConversationLedger, plans: StandingPlans) -> any SkillService {
        // By the plan's origin, so a friend added later is part of it too
        // (P15-E request 14).
        SwapPhotosService(outbox: outbox, ledger: ledger, me: me, planLookup: { conversation in
            await plans.plan(origin: conversation)
        })
    }

    /// Lane E's Change the plan over the app's one Outbox and the ledger it
    /// enforces, finding each plan by its origin (P15-E request 10), and
    /// sharing the holds with Pick a place (ADR 0023). Its journal of
    /// confirmations and leave notices still owed an acknowledgment is on
    /// disk, so a restart keeps resending them.
    static func changePlan(me: PeerID, outbox: Outbox, ledger: any ConversationLedger, plans: StandingPlans,
                           holds: any PlanChangeHolding) -> any SkillService {
        let journal: any ChangePlanJournal = (try? FileChangePlanJournal.standard()) ?? UnavailableChangePlanJournal()
        return ChangePlanService(outbox: outbox, ledger: ledger, journal: journal, holds: holds, me: me, planLookup: { conversation in
            await plans.standing(origin: conversation)
        })
    }

    static func settingsStore() -> any OwnerSettingsStore {
        (try? FileOwnerSettingsStore.standard()) ?? InMemoryOwnerSettingsStore()
    }

    /// Lane G's engine for one snapshot of the owner's rules and the
    /// on-device-only choice in You (StarlingPolicy README). `peers` lets
    /// "Share" apply to paired friends only; without a store the policy asks.
    static func policy(peers: (any PairedPeerStore)?) -> @Sendable (OwnerRules, Bool) -> any PolicyEngine {
        { rules, onlyOnDevice in DeterministicPolicyEngine(ownerRules: rules, onlyOnDeviceAgents: onlyOnDevice, pairedPeers: peers) }
    }

    /// The local record of what left the phone. In memory only, latest 1,000
    /// sends; it forgets on relaunch (StarlingPolicy README, "Audit semantics").
    /// The initializer throws only for a capacity below 1.
    static let auditLog: InMemoryAuditLog = try! InMemoryAuditLog()

    /// The consent sheet's content comes from lane G's `ConsentSheetModel`,
    /// so the sheet says exactly what the policy computed would be sent.
    static let presentConsent: @Sendable (Disclosure) -> ConsentPresentation = { disclosure in
        let model = ConsentSheetModel(disclosure: disclosure)
        return ConsentPresentation(
            rows: model.rows.map { DisplayLine(title: $0.title, detail: $0.detail) },
            recipientModel: model.recipientModelDescription,
            notices: [model.localityNotice, model.psiNotice, model.protocolNotice].compactMap(\.self)
        )
    }
}

/// Swap photos keeps a retirement its ledger could not record and retries
/// it; the app asks at launch and on foreground (P15-E request 4.8).
extension SwapPhotosService: @retroactive RetriesRetirements {}

/// Posts plan notifications and shows them while Starling is open.
final class UserNotificationsNotifier: NSObject, PlanNotifier, UNUserNotificationCenterDelegate {
    static let shared = UserNotificationsNotifier()

    /// Call at launch so banners appear in the foreground too.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// `notDetermined` until iOS has asked (UNNotificationSettings).
    func access() async -> NotificationAccess {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
    }

    func post(_ notice: LifecycleNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = "plans"
        // The same identifier replaces an earlier banner for this interaction.
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// Browses for Starling's Bonjour service, which makes iOS show the Local
/// Network alert (TN3179: "Browsing for Bonjour services" requires local
/// network access). Waits until browsing works, meaning the owner allowed
/// it or already had, or gives up after `timeout` so the first Pair or
/// request never hangs if they tapped Don't Allow.
struct BonjourLocalNetworkPrompter: LocalNetworkPrompter {
    /// Listed in NSBonjourServices in Info.plist.
    static let serviceType = "_starling._tcp"
    var timeout: Duration = .seconds(30)

    func prompt() async {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        let (states, continuation) = AsyncStream.makeStream(of: NWBrowser.State.self)
        browser.stateUpdateHandler = { continuation.yield($0) }
        browser.start(queue: DispatchQueue(label: "starling.local-network-prompt"))
        let waiting = Task {
            for await state in states {
                switch state {
                case .ready, .failed, .cancelled: return
                default: continue
                }
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            waiting.cancel()
        }
        await waiting.value
        timer.cancel()
        browser.cancel()
        continuation.finish()
    }
}
