import Foundation
import Network
import StarlingAgent
import StarlingCore
import StarlingFeatures
import UserNotifications

extension AppServices {
    /// Release builds: real implementations only, never StarlingFakes.
    /// Down, pairing, and the friends list stay nil until lanes E1, E2, and F
    /// merge; their screens say they are not in this build.
    static func release() -> AppServices {
        AppServices(
            agent: FoundationModelsAgent(),
            rules: LiveServices.rulesStore(),
            peers: nil,
            makeDownService: nil,
            makePairingSession: nil,
            notifier: UserNotificationsNotifier.shared,
            localNetwork: BonjourLocalNetworkPrompter()
        )
    }
}

enum LiveServices {
    static func rulesStore() -> any RulesStore {
        (try? FileRulesStore.standard()) ?? InMemoryRulesStore()
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
