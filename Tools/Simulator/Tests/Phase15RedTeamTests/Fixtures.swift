import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes

enum P15 {
    /// Host scheduling is not a protocol deadline. Check the condition even
    /// after a delayed wake, and exclude machine sleep from the wait budget.
    static func eventually(
        _ description: String,
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while true {
            try Task.checkCancellation()
            if try await condition() { return }
            guard clock.now < deadline else { throw SimulationError.timedOut(description) }
            try await clock.sleep(for: .milliseconds(10))
        }
    }

    static func waitForMesh(_ simulation: Simulation) async throws {
        let agents = await simulation.agents
        try await eventually("authenticated mesh of \(agents.count)") {
            for agent in agents where await agent.peerCards.count < agents.count - 1 { return false }
            return true
        }
    }

    static let date = Date(timeIntervalSince1970: 1_790_967_600)
    static let now = Timestamp(date)
    static let alice = try! PeerID(hex: String(repeating: "aa", count: 32))
    static let bob = try! PeerID(hex: String(repeating: "bb", count: 32))
    static let eve = try! PeerID(hex: String(repeating: "ee", count: 32))
    static let slot = try! TimeSlot(startMinute: 29_849_460, endMinute: 29_849_520)
    static let allFlags = SkillFlags(Set(SampleSkills.all.map(\.id)))

    static func interaction(_ skill: SkillDescriptor = SampleSkills.downFor) -> Interaction {
        Interaction(skill: skill.ref, role: .invitee, participants: [alice, bob], createdAt: now)
    }
    static func proposal(_ revision: UInt32, activity: String = "boba") throws -> SkillProposal {
        SkillProposal(revision: revision, participants: [alice, bob],
                      terms: try Terms([.activity: .keywords([try Keyword(activity)]), .time: .slots([slot])]))
    }
    static func question(_ revision: UInt32, issue: IssueKey = .time) throws -> SkillQuestion {
        SkillQuestion(revision: revision, issue: issue, candidates: try value(issue), asker: bob)
    }
    static func restart(_ interaction: Interaction) throws -> Interaction {
        try JSONDecoder().decode(Interaction.self, from: JSONEncoder().encode(interaction))
    }
    static func card(_ skills: [SkillRef]) throws -> AgentCard {
        try AgentCard(model: .onDevice, capabilities: [], skills: skills)
    }
    static func value(_ issue: IssueKey) throws -> IssueValue {
        switch issue {
        case .time: .slots([slot])
        case .place: .places([try PlaceChoice(name: PlaceName("Boba Guys"))])
        case .budget: .amount(try MoneyAmount(minorUnits: 1500))
        case .people: .peers([alice, bob])
        case .partySize, .photos: .count(2)
        default: .keywords([try Keyword("boba")])
        }
    }
    static func bodies(issue: IssueKey, value: IssueValue) throws -> [MessageBody] {
        let terms = try Terms([issue: value])
        return [
            .propose(try Proposal(round: 0, terms: terms)),
            .counter(try Proposal(round: 1, terms: terms)),
            .accept(Acceptance(proposal: MessageID(), terms: terms)),
            .query(try Query(issue: issue, candidates: value)),
            .answer(try Answer(query: MessageID(), issue: issue, status: .answered, acceptable: value)),
        ]
    }
}
