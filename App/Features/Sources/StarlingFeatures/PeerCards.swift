import Foundation
import Observation
import StarlingCore

/// The agent cards paired friends sent in their `hello`s: where each
/// friend's model says it runs, and which skills it runs (ADR 0010). Friends
/// shows them, New leaves out friends whose Starling doesn't do a skill,
/// and Keep it going hides chains a friend cannot run.
///
/// Only cards from paired friends are kept: the secure channel has
/// authenticated the sender, and nobody else's claims matter here. Cards
/// are kept on the phone so support is known while a friend is away.
@MainActor
@Observable
public final class PeerCards {
    public private(set) var cards: [PeerID: AgentCard] = [:]

    private let file: JSONFile?
    private let isFriend: @MainActor (PeerID) -> Bool

    /// - Parameters:
    ///   - file: Where cards are kept between launches, or nil for memory only.
    ///   - isFriend: Whether a sender is a paired friend right now.
    public init(file: JSONFile?, isFriend: @escaping @MainActor (PeerID) -> Bool) {
        self.file = file
        self.isFriend = isFriend
    }

    public func load() {
        guard let file, let stored = try? file.read([String: AgentCard].self) else { return }
        for (hex, card) in stored {
            if let peer = try? PeerID(hex: hex) { cards[peer] = card }
        }
    }

    public func card(for peer: PeerID) -> AgentCard? { cards[peer] }

    /// Whether `peer` runs `skill` at a compatible version, or nil if no card
    /// has arrived yet (the skill's service checks again when it starts).
    public func support(of peer: PeerID, for skill: SkillRef) -> SkillSupport? {
        cards[peer]?.support(for: skill)
    }

    /// Every event from the app's Inbox loop; keeps `hello` cards.
    public func handle(_ event: InboxEvent) {
        guard case .message(let envelope) = event, case .hello(let card) = envelope.body, isFriend(envelope.sender) else { return }
        guard cards[envelope.sender] != card else { return }
        cards[envelope.sender] = card
        save()
    }

    /// Forgets an unpaired friend's card.
    public func forget(_ peer: PeerID) {
        guard cards.removeValue(forKey: peer) != nil else { return }
        save()
    }

    private func save() {
        guard let file else { return }
        try? file.write(Dictionary(uniqueKeysWithValues: cards.map { ($0.key.hex, $0.value) }))
    }
}

extension AgentCard {
    /// This agent's card: where its model runs and the skills the owner has
    /// on (`SkillRegistry.advertised`). `psi` is listed while a skill in the
    /// build uses mutual reveal, which runs over PSI.
    public static func forBuild(skills: [SkillRef], usesPSI: Bool, locality: ModelLocality) -> AgentCard {
        // Cannot throw: one protocol version, at most one capability, and the
        // registry holds each skill once.
        try! AgentCard(model: locality, capabilities: usesPSI ? [.psi] : [], skills: Array(skills.prefix(ProtocolLimits.maxSkillsAdvertised)))
    }
}
