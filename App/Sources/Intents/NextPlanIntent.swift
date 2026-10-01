import AppIntents
import Foundation
import StarlingCore
import StarlingFeatures
import StarlingIdentity

/// The intents live in StarlingFeatures, where tests check that each one
/// that reads plans or names requires an unlocked phone (ADR 0204).
struct StarlingAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [StarlingFeaturesIntents.self] }
}

extension PlanReader {
    /// Reads the interactions on this phone and says the next plan; it
    /// changes nothing and sends nothing.
    static let live = PlanReader {
        let interactions = (try? await LiveServices.interactionStore().all()) ?? []
        let friends = (try? await KeychainPairedPeerStore().all()) ?? []
        let names = Dictionary(friends.map { ($0.id, $0.nickname) }, uniquingKeysWith: { first, _ in first })
        let me = try? await KeychainIdentityKeyStore().loadOrCreate().peerID
        let words = InteractionWords(registry: LiveServices.registry, localPeer: me, formatter: ValueFormatter(), names: { names })
        return NextPlanAnswer.text(interactions, words: words, now: Date())
    }
}

struct StarlingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextPlanIntent(),
            phrases: ["What's my next plan in \(.applicationName)", "Next plan in \(.applicationName)"],
            shortTitle: "Next plan",
            systemImageName: "calendar"
        )
    }
}
