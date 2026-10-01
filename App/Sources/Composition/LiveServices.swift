import Foundation
import Network
import StarlingAgent
import StarlingCore
import StarlingFeatures
import StarlingIdentity
import StarlingPolicy
import StarlingWiFiAware
import UserNotifications

extension AppServices {
    /// Release builds: real implementations only, never StarlingFakes
    /// (ADR 0140). Lane E1's identity, pinned friends, pairing, and secure
    /// links; lane G's policy and audit log; lane E2's Wi-Fi Aware. No skill
    /// service is in the build until the skill lanes merge (B, C, D, E), so
    /// New shows each tile as "Not in this build yet" instead of running a
    /// fake. Permission access APIs arrive with lanes C and D.
    static func release() async throws -> AppServices {
        let identity = try await KeychainIdentityKeyStore().loadOrCreate()
        let links = SecureLinks.make(identity: identity, friends: KeychainPairedPeerStore())
        return AppServices(
            agent: FoundationModelsAgent(),
            registry: LiveServices.registry,
            interactions: LiveServices.interactionStore(),
            settings: LiveServices.settingsStore(),
            rules: LiveServices.rulesStore(),
            peers: links.friends,
            pairing: links.pairingDirectory,
            unpair: links.unpair,
            rename: links.rename,
            inboxEvents: links.inboxEvents,
            makePolicy: LiveServices.policy(peers: links.friends),
            auditLog: LiveServices.auditLog,
            describeEgress: LiveServices.describeEgress,
            transport: links.transport,
            afterStart: links.startPairing,
            agentLocality: .onDevice,
            presentConsent: LiveServices.presentConsent,
            notifier: UserNotificationsNotifier.shared,
            localNetwork: BonjourLocalNetworkPrompter(),
            cardsFile: try? .standard("peer-cards.json"),
            notesFile: try? .standard("plan-notes.json")
        )
    }
}

enum LiveServices {
    /// Every Phase 1.5 skill's descriptor, until each skill package ships
    /// its own. Data only: a descriptor runs nothing without its service.
    /// The values match StarlingFakes.SampleSkills, which Release cannot link.
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
            ])
        ),
        try! SkillDescriptor(
            ref: SkillRef(.findATime, SkillVersion(1)),
            wording: SkillWording(name: "Find a time", summary: "Agree on when", startAction: "Find a time",
                                  acceptAction: "That works", declineAction: "Not then", declineNote: "If you pass, they just won't see it."),
            buildingBlock: .privateQuery, topicsUsed: [.time, .activity], topicsRequired: [.time],
            permissions: [.calendarFullAccess], produces: [.timeSlot, .plan],
            intent: IntentSchema(slots: [
                IntentSlot(.time, required: true, hint: "the range to look in, such as next week"),
                IntentSlot(.activity, required: false, hint: "what it is for, such as stats"),
            ])
        ),
        try! SkillDescriptor(
            ref: SkillRef(.pickAPlace, SkillVersion(1)),
            wording: SkillWording(name: "Pick a place", summary: "Agree on where", startAction: "Find a place",
                                  acceptAction: "Sounds good", declineAction: "Somewhere else", declineNote: "If you pass, they just won't see it."),
            buildingBlock: .privateAggregation, topicsUsed: [.place, .budget, .diet], topicsRequired: [.place],
            permissions: [.locationWhenInUse], accepts: [.plan, .timeSlot], produces: [.placeChoice],
            intent: IntentSchema(slots: [
                IntentSlot(.place, required: false, hint: "the kind of place or area, such as near Franklin"),
                IntentSlot(.budget, required: false, hint: "the most they want to spend"),
                IntentSlot(.diet, required: false, hint: "what they can't eat"),
            ])
        ),
    ])

    static func rulesStore() -> any RulesStore {
        (try? FileRulesStore.standard()) ?? InMemoryRulesStore()
    }

    static func interactionStore() -> any InteractionStore {
        (try? FileInteractionStore.standard())
            ?? FileInteractionStore(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "interactions.json")))
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

    /// The items a send the policy allowed without a sheet disclosed, the
    /// same way the policy computes them for a sheet (ADR 0201 decision 5).
    static let describeEgress: @Sendable (Envelope, OutboundContext) -> [DisclosedItem] = { envelope, context in
        let message = OutboundMessage(envelope: envelope, recipientCard: nil, transport: .loopback, context: context)
        return (try? DeterministicPolicyEngine().disclosure(for: message).items) ?? []
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
