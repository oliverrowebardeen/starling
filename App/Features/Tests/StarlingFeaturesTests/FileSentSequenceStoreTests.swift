import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@Suite struct FileSentSequenceStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-seq-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "sent-sequences.json")) }

    @Test func theHighestNumberSurvivesARelaunch() throws {
        let conversation = ConversationID()
        let store = FileSentSequenceStore(file: file)
        #expect(store.highestSent(in: conversation) == nil)
        try store.recordSent(41, in: conversation)
        try store.recordSent(40, in: conversation)
        #expect(store.highestSent(in: conversation) == 41)
        #expect(FileSentSequenceStore(file: file).highestSent(in: conversation) == 41)
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

    @Test func aWriteThatFailsStopsTheSendAndRecordsNothing() throws {
        // A regular file where the directory should be: every write fails.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "blocked")
        try Data().write(to: blocker)
        let store = FileSentSequenceStore(file: JSONFile(url: blocker.appending(path: "sent-sequences.json")))
        let conversation = ConversationID()
        #expect(throws: (any Error).self) { try store.recordSent(7, in: conversation) }
        #expect(store.highestSent(in: conversation) == nil)
    }

    /// Re-review of PR #54, finding 4: nothing is evicted by count, so a
    /// live conversation's number is never forgotten however many others
    /// (hello traffic included) are used.
    @Test func noConversationIsEvictedByCount() throws {
        let store = FileSentSequenceStore(file: file)
        let live = ConversationID()
        try store.recordSent(9, in: live)
        for _ in 0..<1_100 { try store.recordSent(1, in: ConversationID()) }
        #expect(FileSentSequenceStore(file: file).highestSent(in: live) == 9)
    }

    @Test func retainingKeepsOnlyResumableConversations() throws {
        let store = FileSentSequenceStore(file: file)
        let a = ConversationID(), b = ConversationID()
        try store.recordSent(5, in: a)
        try store.recordSent(6, in: b)
        try store.retainOnly([a])
        let reopened = FileSentSequenceStore(file: file)
        #expect(reopened.highestSent(in: a) == 5)
        #expect(reopened.highestSent(in: b) == nil)
        #expect(reopened.conversationCount == 1)
    }

    @Test func anUnreadableFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let store = FileSentSequenceStore(file: file)
        #expect(store.quarantined != nil)
        try store.recordSent(3, in: ConversationID())
    }
}
