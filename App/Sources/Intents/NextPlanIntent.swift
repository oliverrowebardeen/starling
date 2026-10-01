import AppIntents
import Foundation
import StarlingCore
import StarlingFeatures
import StarlingIdentity

/// Plans exposed to Siri, Shortcuts, and Spotlight through App Intents
/// (ADR 0018 decision 4). It reads the interactions on this phone and says
/// the next plan; nothing is sent anywhere.
struct NextPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "What's my next plan?"
    static let description = IntentDescription("Says your next plan with friends, from Starling on this iPhone.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let interactions = (try? await LiveServices.interactionStore().all()) ?? []
        let friends = (try? await KeychainPairedPeerStore().all()) ?? []
        let names = Dictionary(friends.map { ($0.id, $0.nickname) }, uniquingKeysWith: { first, _ in first })
        let me = try? await KeychainIdentityKeyStore().loadOrCreate().peerID
        let words = InteractionWords(registry: LiveServices.registry, localPeer: me, formatter: ValueFormatter(), names: { names })
        return .result(dialog: IntentDialog(stringLiteral: NextPlanAnswer.text(interactions, words: words, now: Date())))
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
