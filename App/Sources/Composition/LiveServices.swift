import Foundation
import Network
import StarlingAgent
import StarlingCore
import StarlingFeatures
import StarlingIdentity
import StarlingNegotiation
import StarlingPolicy
import StarlingWiFiAware
import UserNotifications

extension AppServices {
    /// Release builds: real implementations only, never StarlingFakes.
    /// Lane E1's identity, pinned friends, pairing, and secure links, lane
    /// G's policy and audit log, lane E2's Wi-Fi Aware. Down stays out: lane
    /// F's DownNegotiator needs a PSI provider and the only one,
    /// InsecurePSIStub, lives in StarlingFakes, so Release shows "Down? isn't
    /// in this build yet" until a private provider (Nightjar) exists.
    static func release() async throws -> AppServices {
        let identity = try await KeychainIdentityKeyStore().loadOrCreate()
        let links = SecureLinks.make(identity: identity, friends: KeychainPairedPeerStore())
        return AppServices(
            agent: FoundationModelsAgent(),
            rules: LiveServices.rulesStore(),
            peers: links.friends,
            makeDownService: nil,
            pairing: links.pairingDirectory,
            unpair: links.unpair,
            // No rename: lane E1 has no rename through the PinAuthority, and a
            // direct store write could race an unpair (docs/requests/H.md 6).
            rename: nil,
            inboxEvents: links.inboxEvents,
            makePolicy: LiveServices.policy(peers: links.friends),
            auditLog: LiveServices.auditLog,
            transport: links.transport,
            afterStart: links.startPairing,
            agentLocality: .onDevice,
            describeDownError: LiveServices.describeDownError,
            presentConsent: LiveServices.presentConsent,
            notifier: UserNotificationsNotifier.shared,
            localNetwork: BonjourLocalNetworkPrompter()
        )
    }
}

enum LiveServices {
    static func rulesStore() -> any RulesStore {
        (try? FileRulesStore.standard()) ?? InMemoryRulesStore()
    }

    /// Lane G's engine for one snapshot of the owner's rules (StarlingPolicy
    /// README). `onlyOnDeviceAgents` stays off until the app has a setting
    /// for it, so cloud agents get a consent sheet on every message instead
    /// of a refusal. `peers` lets "share with on-device agents" apply to
    /// paired friends only; without a store the policy asks.
    static func policy(peers: (any PairedPeerStore)?) -> @Sendable (OwnerRules) -> any PolicyEngine {
        { rules in DeterministicPolicyEngine(ownerRules: rules, onlyOnDeviceAgents: false, pairedPeers: peers) }
    }

    /// Plain words for lane F's own setIntent errors (docs/requests/F.md).
    static let describeDownError: @Sendable (any Error) -> String? = { error in
        switch error as? DownError {
        case .expired: "This Down? would already be over. Pick a later end time."
        case .noAvailableTime: "Your rules leave no free half-hour before this ends. Change the times or pick a later end."
        case nil: nil
        }
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

/// Posts match notifications and shows them while Starling is open.
final class UserNotificationsNotifier: NSObject, MatchNotifier, UNUserNotificationCenterDelegate {
    static let shared = UserNotificationsNotifier()

    /// Call at launch so banners appear in the foreground too.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ notice: MatchNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = "down-matches"
        // The same identifier replaces an earlier banner for this friend.
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
/// it or already had, or gives up after `timeout` so onboarding never hangs
/// if they tapped Don't Allow.
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

/// Lane F requires shutdown() when the app tears the service down.
/// Retroactive because StarlingNegotiation does not depend on
/// StarlingFeatures, so lane F can never add this conformance itself.
extension DownNegotiator: @retroactive StoppableDownService {}
