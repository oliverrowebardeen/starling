import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@Suite struct FileSentSequenceStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-seq-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "sent-sequences.json")) }
    let maya = PeerID.random()
    let jake = PeerID.random()

    @Test func theHighestNumberSurvivesARelaunch() throws {
        let conversation = ConversationID()
        let store = FileSentSequenceStore(file: file)
        #expect(store.highestSent(in: conversation, to: maya) == nil)
        try store.recordSent(41, in: conversation, to: maya)
        try store.recordSent(40, in: conversation, to: maya)
        #expect(store.highestSent(in: conversation, to: maya) == 41)
        #expect(FileSentSequenceStore(file: file).highestSent(in: conversation, to: maya) == 41)
    }

    /// Outbox continues above the recorded number after a relaunch, even
    /// with a clock set back before it.
    @Test func outboxContinuesAboveWhatWasSentBefore() async throws {
        let conversation = ConversationID()
        let peer = PeerID.random()
        let transport = RecordingTransport()
        let later = Date(timeIntervalSince1970: 2_000_000_000)
        let first = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                           sequences: FileSentSequenceStore(file: file), now: { later })
        let sent = try await first.send(.propose(try Proposal(round: 0, terms: .empty)), to: peer, conversation: conversation)

        let earlier = Date(timeIntervalSince1970: 1_000_000_000)
        let relaunched = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                sequences: FileSentSequenceStore(file: file), now: { earlier })
        let next = try await relaunched.send(.propose(try Proposal(round: 0, terms: .empty)), to: peer, conversation: conversation)
        #expect(next.sequence > sent.sequence)
    }

    /// ADR 0021 decision 8: numbers run per friend, so one friend's number
    /// says nothing about another's.
    @Test func numbersAreKeptPerRecipient() throws {
        let conversation = ConversationID()
        let store = FileSentSequenceStore(file: file)
        try store.recordSent(9, in: conversation, to: maya)
        try store.recordSent(2, in: conversation, to: jake)
        let reopened = FileSentSequenceStore(file: file)
        #expect(reopened.highestSent(in: conversation, to: maya) == 9)
        #expect(reopened.highestSent(in: conversation, to: jake) == 2)
    }

    /// A file from before numbers were per recipient keeps each old number
    /// as a floor for every recipient in that conversation.
    @Test func anOlderPerConversationEntryIsAFloor() throws {
        let conversation = ConversationID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"version":1,"sent":{"\#(conversation.rawValue.uuidString)":{"highest":50,"used":1}}}"#
        try Data(json.utf8).write(to: file.url)
        let store = FileSentSequenceStore(file: file)
        #expect(store.highestSent(in: conversation, to: maya) == 50)
        try store.recordSent(51, in: conversation, to: maya)
        #expect(store.highestSent(in: conversation, to: maya) == 51)
        #expect(store.highestSent(in: conversation, to: jake) == 50)
        try store.retainOnly([conversation])
        #expect(FileSentSequenceStore(file: file).highestSent(in: conversation, to: jake) == 50)
    }

    @Test func aWriteThatFailsStopsTheSendAndRecordsNothing() throws {
        // A regular file where the directory should be: every write fails.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "blocked")
        try Data().write(to: blocker)
        let store = FileSentSequenceStore(file: JSONFile(url: blocker.appending(path: "sent-sequences.json")))
        let conversation = ConversationID()
        #expect(throws: (any Error).self) { try store.recordSent(7, in: conversation, to: maya) }
        #expect(store.highestSent(in: conversation, to: maya) == nil)
    }

    /// Re-review of PR #54, finding 4: nothing is evicted by count, so a
    /// live conversation's number is never forgotten however many others
    /// (hello traffic included) are used.
    @Test func noConversationIsEvictedByCount() throws {
        let store = FileSentSequenceStore(file: file)
        let live = ConversationID()
        try store.recordSent(9, in: live, to: maya)
        for _ in 0..<1_100 { try store.recordSent(1, in: ConversationID(), to: maya) }
        #expect(FileSentSequenceStore(file: file).highestSent(in: live, to: maya) == 9)
    }

    @Test func retainingKeepsOnlyResumableConversations() throws {
        let store = FileSentSequenceStore(file: file)
        let a = ConversationID(), b = ConversationID()
        try store.recordSent(5, in: a, to: maya)
        try store.recordSent(6, in: b, to: maya)
        try store.retainOnly([a])
        let reopened = FileSentSequenceStore(file: file)
        #expect(reopened.highestSent(in: a, to: maya) == 5)
        #expect(reopened.highestSent(in: b, to: maya) == nil)
        #expect(reopened.conversationCount == 1)
    }

    @Test func anUnreadableFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let store = FileSentSequenceStore(file: file)
        #expect(store.quarantined != nil)
        try store.recordSent(3, in: ConversationID(), to: maya)
    }
}
