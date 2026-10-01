import Foundation
import StarlingCore
import StarlingFakes

/// You, Maya, and Jake, planning boba (the mockups' plan).
enum Fixtures {
    static let me = try! PeerID(bytes: Data(repeating: 0xAA, count: 32))
    static let maya = try! PeerID(bytes: Data(repeating: 0xBB, count: 32))
    static let jake = try! PeerID(bytes: Data(repeating: 0xCC, count: 32))
    static let stranger = try! PeerID(bytes: Data(repeating: 0xDD, count: 32))
    /// 2026-10-02 19:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_967_600)

    static func at(minutes: Int) -> Timestamp { Timestamp(now.addingTimeInterval(Double(minutes) * 60)) }
    static func date(minutes: Int) -> Date { now.addingTimeInterval(Double(minutes) * 60) }

    static let boba = try! Keyword("boba")
    /// Tonight, 8:30 to 10:30, as in the plan detail mockup.
    static let tonight = try! TimeSlot(start: date(minutes: 90), end: date(minutes: 210))

    static let flagsWithSwapPhotos = SkillFlags(SkillFlags.phase1_5.enabled.union([.swapPhotos]))

    static func card(_ skills: [SkillDescriptor], model: ModelLocality = .onDevice) -> AgentCard {
        try! AgentCard(model: model, capabilities: [], skills: skills.map(\.ref))
    }

    static func cards(_ skills: [SkillDescriptor] = SampleSkills.all) -> [PeerID: AgentCard] {
        [maya: card(skills), jake: card(skills)]
    }

    /// A Down for… interaction that reached "It's a plan" with a recorded
    /// plan, started at minute 0 and planned at minute 4.
    static func plannedDownFor(time: TimeSlot? = tonight, role: InteractionRole = .initiator) throws -> Interaction {
        let others = [maya, jake]
        var interaction = Interaction(skill: SampleSkills.downFor.ref, role: role, participants: others, createdAt: at(minutes: 0))
        if role == .initiator { try interaction.apply(.started, at: at(minutes: 1)) }
        let plan = try Plan(origin: interaction.conversation, attendees: Attendees([me, maya, jake]), activity: boba, time: time)
        let terms = try Terms([.activity: .keywords([boba])])
        try interaction.apply(.proposalReady(SkillProposal(revision: 1, participants: [me, maya, jake], terms: terms, plan: plan)), at: at(minutes: 2))
        try interaction.apply(.ownerAccepted(revision: 1), at: at(minutes: 3))
        try interaction.apply(.everyoneConfirmed(revision: 1), at: at(minutes: 4))
        interaction.record(.plan(plan))
        return interaction
    }

    static func place(_ name: String = "Boba Guys") -> PlaceChoice {
        try! PlaceChoice(name: PlaceName(name))
    }
}
