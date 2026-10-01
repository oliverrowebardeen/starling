import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@Suite struct FileInteractionStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-store-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "interactions.json")) }

    static func interaction(at ms: Int64, role: InteractionRole = .initiator) -> Interaction {
        Interaction(skill: SampleSkills.downFor.ref, role: role, participants: [.random()], createdAt: Timestamp(millisecondsSince1970: ms))
    }

    @Test func savedInteractionsSurviveANewStore() async throws {
        var first = Self.interaction(at: 1)
        try first.apply(.started, at: Timestamp(millisecondsSince1970: 2))
        let proposal = SkillProposal(revision: 1, participants: first.participants, terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        try first.apply(.proposalReady(proposal), at: Timestamp(millisecondsSince1970: 3))
        let second = Self.interaction(at: 5, role: .invitee)
        let store = FileInteractionStore(file: file)
        try await store.save(second)
        try await store.save(first)

        let reopened = FileInteractionStore(file: file)
        #expect(try await reopened.all() == [first, second])
        #expect(try await reopened.interaction(first.id)?.proposal == proposal)
        #expect(try await reopened.interaction(conversation: second.conversation) == second)
    }

    @Test func saveReplacesAndRemoveDeletes() async throws {
        var item = Self.interaction(at: 1)
        let store = FileInteractionStore(file: file)
        try await store.save(item)
        try item.apply(.started, at: Timestamp(millisecondsSince1970: 2))
        try await store.save(item)
        #expect(try await store.all().map(\.state) == [.negotiating])
        try await store.remove(item.id)
        #expect(try await FileInteractionStore(file: file).all().isEmpty)
    }

    /// A corrupted file is moved aside, never overwritten, so it can still
    /// be recovered by hand.
    @Test func anUnreadableFileIsMovedAsideAndTheStoreStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let store = FileInteractionStore(file: file)
        #expect(try await store.all().isEmpty)
        let aside = try #require(await store.quarantined)
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")

        try await store.save(Self.interaction(at: 1))
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
        #expect(try await FileInteractionStore(file: file).all().count == 1)
    }

    @Test func onlyTheNewestFinishedInteractionsAreKept() async throws {
        let store = FileInteractionStore(file: file, maxFinished: 2)
        var live = Self.interaction(at: 0)
        try live.apply(.started, at: Timestamp(millisecondsSince1970: 0))
        try await store.save(live)
        var finished: [Interaction] = []
        for ms in Int64(1)...4 {
            var item = Self.interaction(at: ms)
            try item.apply(.withdrawn, at: Timestamp(millisecondsSince1970: ms))
            finished.append(item)
            try await store.save(item)
        }
        let kept = try await store.all()
        #expect(kept.map(\.id) == [live.id, finished[2].id, finished[3].id])
    }

    @Test func theFileIsExcludedFromBackups() async throws {
        try await FileInteractionStore(file: file).save(Self.interaction(at: 1))
        #expect(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}
