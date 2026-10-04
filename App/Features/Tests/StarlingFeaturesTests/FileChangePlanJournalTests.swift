import Foundation
import StarlingChangePlan
import StarlingCore
@testable import StarlingFeatures
import Testing

@Suite struct FileChangePlanJournalTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-change-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "change-plan-journal.json")) }

    /// One of lane E's records, built from its stored form.
    func applied() throws -> ChangePlanRecord {
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode([value]), options: [.fragmentsAllowed]) as! [Any] }
        let body: [String: Any] = [
            "interaction": (try json(InteractionID()) as! [Any])[0],
            "conversation": (try json(ConversationID()) as! [Any])[0],
            "planConversation": (try json(ConversationID()) as! [Any])[0],
            "suggester": (try json(PeerID.random()) as! [Any])[0],
            "offer": (try json(MessageID()) as! [Any])[0],
            "until": (try json(Date().addingTimeInterval(3600)) as! [Any])[0],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["applied": ["_0": body]])
        return try JSONDecoder().decode(ChangePlanRecord.self, from: data)
    }

    /// P15-E request 10: what is owed survives a relaunch until removed.
    @Test func recordsSurviveARelaunchUntilRemoved() async throws {
        let record = try applied()
        try await FileChangePlanJournal(file: file).save(record)
        try await FileChangePlanJournal(file: file).save(record)
        #expect(try await FileChangePlanJournal(file: file).records() == [record])
        try await FileChangePlanJournal(file: file).remove(record.key)
        #expect(try await FileChangePlanJournal(file: file).records().isEmpty)
    }

    @Test func anUnreadableJournalThrowsRatherThanReadingAsNothingOwed() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        await #expect(throws: FileChangePlanJournal.Unreadable.self) { try await FileChangePlanJournal(file: file).records() }
    }
}
