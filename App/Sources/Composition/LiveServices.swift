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
    /// links; lane G's policy and audit log; lane E2's Wi-Fi Aware. No skill
    /// service is in the build until the skill lanes merge (B, C, D, E), so
    /// New shows each tile as "Not in this build yet" instead of running a
    /// fake. Permission access APIs arrive with lanes C and D.
    @MainActor
    static func release() async throws -> AppServices {
        let identity = try await KeychainIdentityKeyStore().loadOrCreate()
        let links = SecureLinks.make(identity: identity, friends: KeychainPairedPeerStore())
        let ledger = LiveServices.ledger()
        let rules = LiveServices.rulesStore()
        let places = LiveServices.places()
        let interactions = LiveServices.interactionStore()
        return AppServices(
            agent: FoundationModelsAgent(),
            registry: LiveServices.registry,
            makeSkills: { outbox in
                [
                    LiveServices.pickAPlace(me: identity.peerID, outbox: outbox, friends: links.friends, staged: places.staged, rules: rules, ledger: ledger),
                    LiveServices.swapPhotos(me: identity.peerID, outbox: outbox, ledger: ledger, interactions: interactions),
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
    /// Every Phase 1.5 skill's descriptor: lane D's Pick a place and lane
    /// E's Swap photos from their packages; Down for… and Find a time match
    /// StarlingFakes.SampleSkills, which Release cannot link, until their
    /// packages merge. Data only: a descriptor runs nothing without its
    /// service.
    static let registry: SkillRegistry = try! SkillRegistry([
        try! SkillDescriptor(
            ref: SkillRef(.downFor, SkillVersion(1)),
            wording: SkillWording(name: "Down for…", summary: "See who's up for something", startAction: "See who's up for it",
                                  acceptAction: "I'm in", declineAction: "Not tonight", declineNote: "If you pass, they just won't see it."),
            buildingBlock: .mutualReveal, topicsUsed: [.time, .activity, .place, .budget], topicsRequired: [.time, .activity],
            accepts: [.timeSlot], produces: [.plan],
            intent: IntentSchema(slots: [
                IntentSlot(.activity, required: true, hint: "what they want to do, such as boba or a walk"),
                IntentSlot(.time, required: false, hint: "when, such as tonight after 7"),
                IntentSlot(.place, required: false, hint: "where or how far, such as nearby"),
                IntentSlot(.budget, required: false, hint: "the most they want to spend"),
            ]),
            sendModes: [.askQuietly, .invite]
        ),
        try! SkillDescriptor(
            ref: SkillRef(.findATime, SkillVersion(1)),
            wording: SkillWording(name: "Find a time", summary: "Agree on when", startAction: "Find a time",
                                  acceptAction: "That works", declineAction: "Not then", declineNote: "If you pass, they just won't see it."),
            // Calendar details are read on the phone only (ADR 0019).
            buildingBlock: .privateQuery, topicsUsed: [.time, .activity, .people, .calendarDetails], topicsRequired: [.time],
            permissions: [.calendarFullAccess], produces: [.timeSlot, .plan],
            intent: IntentSchema(slots: [
                IntentSlot(.time, required: true, hint: "the range to look in, such as next week"),
                IntentSlot(.activity, required: false, hint: "what it is for, such as stats"),
            ])
        ),
        PickAPlaceSkill.descriptor,
        SwapPhotos.descriptor,
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

    /// Lane D's service over the app's one Outbox and the same conversation
    /// ledger the Outbox enforces (P15-D request 3).
    static func pickAPlace(me: PeerID, outbox: Outbox, friends: any PairedPeerStore, staged: StagedCandidates,
                           rules: any RulesStore, ledger: any ConversationLedger) -> any SkillService {
        PickAPlaceService(
            localPeer: me, outbox: outbox, pairedPeers: friends, candidates: staged, maps: MapKitPlaceSearch(),
            // The owner's standing budget, diet, and place limits, read when
            // a friend asks; the organizer's own come with its request.
            ownerLimits: { (try? await rules.load())?.rules.constraints ?? .empty },
            ledger: UserDefaultsPickAPlaceLedger(), conversations: ledger
        )
    }

    /// Lane E's Swap photos over the app's one Outbox and the same
    /// conversation ledger it enforces (P15-E request 4.8). An offer is
    /// checked against the plan saved on this phone. Runs only while its
    /// flag is on (AppModel drops a flagged-off service).
    static func swapPhotos(me: PeerID, outbox: Outbox, ledger: any ConversationLedger, interactions: any InteractionStore) -> any SkillService {
        SwapPhotosService(outbox: outbox, ledger: ledger, me: me, planLookup: { conversation in
            try? await interactions.interaction(conversation: conversation)?.plan
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
