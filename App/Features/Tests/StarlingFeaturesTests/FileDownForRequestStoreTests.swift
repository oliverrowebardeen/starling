import DownFor
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@Suite struct FileDownForRequestStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-downfor-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "down-for-requests.json")) }

    /// P15-B request 2: lane B's service keeps its request on disk, so a
    /// relaunch can restore it.
    @Test func aRequestSurvivesARelaunch() async throws {
        let store = FileDownForRequestStore(file: file)
        let me = PeerID.random(), maya = PeerID.random()
        let ledger = InMemoryConversationLedger()
        let outbox = Outbox(transport: RecordingTransport(localPeer: me), policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), ledger: ledger)
        let service = DownForService(localPeer: me, outbox: outbox, model: ScriptedAgentModel(), psi: InsecurePSIStub(), ledger: ledger, store: store)
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: DownFor.ref,
                                rules: OwnerRules(constraints: try ConstraintSet([.activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []))]])),
                                audience: .picked([maya]), mode: .askQuietly,
                                expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [maya]
        )
        try await service.start(request)
        await service.shutdown()

        let reopened = try await FileDownForRequestStore(file: file).record(for: request.interaction)
        #expect(reopened?.participants == [maya])
        #expect(reopened?.mode == .askQuietly)
        try await FileDownForRequestStore(file: file).remove(request.interaction)
        #expect(try await FileDownForRequestStore(file: file).record(for: request.interaction) == nil)
    }

    @Test func anUnreadableFileThrowsRatherThanReadingAsEmpty() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        await #expect(throws: FileDownForRequestStore.Unreadable.self) {
            try await FileDownForRequestStore(file: file).record(for: InteractionID())
        }
    }
}
