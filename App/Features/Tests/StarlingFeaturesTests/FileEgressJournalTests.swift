import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@Suite struct FileEgressJournalTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-journal-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "egress-journal.json")) }

    func entry(sent: Bool, message: MessageID = MessageID()) -> EgressJournalEntry {
        EgressJournalEntry(message: message, conversation: ConversationID(),
                           record: EgressRecord(at: Timestamp(Date()), recipient: .random(), items: [], message: message), sent: sent)
    }

    @Test func entriesSurviveARelaunchUntilForgotten() async throws {
        let first = entry(sent: false)
        let second = entry(sent: true)
        let journal = FileEgressJournal(file: file)
        try await journal.remember(first)
        try await journal.remember(second)
        let confirmed = EgressJournalEntry(message: first.message, conversation: first.conversation, record: first.record, sent: true)
        try await journal.remember(confirmed)
        #expect(try await FileEgressJournal(file: file).unresolved() == [confirmed, second])
        try await journal.forget(first.message)
        #expect(try await FileEgressJournal(file: file).unresolved() == [second])
    }

    @Test func anUnreadableJournalThrowsAndTheRecorderSaysSo() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let journal = FileEgressJournal(file: file)
        await #expect(throws: FileEgressJournal.Unreadable.self) { try await journal.unresolved() }
        let recorder = EgressRecorder(sink: StoreEgressSink(store: InMemoryInteractionStore()), journal: journal)
        await recorder.recover()
        #expect(await recorder.journalUnreadable)
    }

    /// A send the journal cannot note never leaves (ADR 0021 decision 4).
    @Test func aJournalThatCannotWriteStopsTheSend() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "blocked")
        try Data().write(to: blocker)
        let recorder = EgressRecorder(sink: StoreEgressSink(store: InMemoryInteractionStore()),
                                      journal: FileEgressJournal(file: JSONFile(url: blocker.appending(path: "egress-journal.json"))))
        let transport = RecordingTransport()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            observer: FanOutObserver([recorder]))
        await #expect(throws: (any Error).self) {
            try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: .random(), conversation: ConversationID())
        }
        #expect(await transport.sent.isEmpty)
    }
}
