import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@MainActor
@Suite struct PeerCardsTests {
    let me = PeerID.random()
    let maya = PeerID.random()
    let stranger = PeerID.random()
    let card = AgentCard.forBuild(skills: [SampleSkills.downFor.ref, SampleSkills.findATime.ref], usesPSI: true, locality: .onDevice)

    func hello(from sender: PeerID, card: AgentCard) throws -> InboxEvent {
        .message(try Envelope(conversation: ConversationID(), sender: sender, recipient: me, sequence: 0, sentAt: Timestamp(Date()), body: .hello(card)))
    }

    @Test func keepsFriendsCardsOnlyAndAnswersSupport() throws {
        let maya = maya
        let cards = PeerCards(file: nil) { $0 == maya }
        cards.handle(try hello(from: maya, card: card))
        cards.handle(try hello(from: stranger, card: card))
        #expect(cards.card(for: maya) == card)
        #expect(cards.card(for: stranger) == nil)
        #expect(cards.support(of: maya, for: SampleSkills.downFor.ref) == .supported(SkillVersion(1)))
        #expect(cards.support(of: maya, for: SampleSkills.pickAPlace.ref) == .missing)
        #expect(cards.support(of: stranger, for: SampleSkills.downFor.ref) == nil)
    }

    @Test func aNewerCardReplacesTheOldOneAndUnpairingForgetsIt() throws {
        let maya = maya
        let cards = PeerCards(file: nil) { $0 == maya }
        cards.handle(try hello(from: maya, card: card))
        let fewer = AgentCard.forBuild(skills: [SampleSkills.downFor.ref], usesPSI: true, locality: .onDevice)
        cards.handle(try hello(from: maya, card: fewer))
        #expect(cards.support(of: maya, for: SampleSkills.findATime.ref) == .missing)
        cards.forget(maya)
        #expect(cards.card(for: maya) == nil)
    }

    @Test func cardsSurviveARelaunch() throws {
        let file = JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "starling-cards-\(UUID().uuidString).json"))
        let maya = maya
        let first = PeerCards(file: file) { $0 == maya }
        first.handle(try hello(from: maya, card: card))
        let second = PeerCards(file: file) { _ in false }
        second.load()
        #expect(second.card(for: maya) == card)
    }

    @Test func thisAgentsCardListsTheSkillsItRuns() {
        #expect(card.skills == [SampleSkills.downFor.ref, SampleSkills.findATime.ref])
        #expect(card.capabilities == [.psi])
        #expect(AgentCard.forBuild(skills: [], usesPSI: false, locality: .onDevice).capabilities.isEmpty)
    }
}
