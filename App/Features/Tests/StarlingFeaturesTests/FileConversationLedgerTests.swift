import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@Suite struct FileConversationLedgerTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "starling-ledger-\(UUID().uuidString)")
    var file: JSONFile { JSONFile(url: directory.appending(path: "ledger.json")) }
    let maya = PeerID.random()

    func keywords(_ count: Int, from start: Int = 0) throws -> [IssueValue] {
        try (start..<(start + count)).map { .keywords([try Keyword("option\(Self.letters($0))")]) }
    }

    /// Keywords are letters only, so number them with letters.
    static func letters(_ n: Int) -> String {
        String(String(n).map { Character(UnicodeScalar(UInt8(97 + Int(String($0))!))) })
    }

    @Test func retirementSurvivesARelaunchForGood() async throws {
        let conversation = ConversationID()
        try await FileConversationLedger(file: file).retire(conversation)
        let reopened = FileConversationLedger(file: file)
        #expect(try await reopened.isRetired(conversation))
        #expect(try await !reopened.isRetired(ConversationID()))
        // A retired conversation takes no more answers.
        #expect(try await !reopened.reserve(try keywords(1), issue: .activity, to: maya, in: conversation))
    }

    /// ADR 0019 decision 6, ADR 0021: at most 16 distinct candidates per
    /// friend, conversation, and issue, kept across launches; asking again
    /// about one already answered costs nothing.
    @Test func answersStopAtSixteenDistinctCandidatesAcrossLaunches() async throws {
        let conversation = ConversationID()
        let ledger = FileConversationLedger(file: file)
        #expect(try await ledger.reserve(try keywords(10), issue: .activity, to: maya, in: conversation))
        #expect(try await ledger.reserve(try keywords(10), issue: .activity, to: maya, in: conversation), "repeats are free")
        let reopened = FileConversationLedger(file: file)
        #expect(try await !reopened.reserve(try keywords(7, from: 10), issue: .activity, to: maya, in: conversation), "17 would pass the limit")
        #expect(try await reopened.reserve(try keywords(6, from: 10), issue: .activity, to: maya, in: conversation), "exactly 16 is allowed")
        #expect(try await reopened.reserve(try keywords(1, from: 20), issue: .budget, to: maya, in: conversation), "another issue has its own budget")
        #expect(try await reopened.reserve(try keywords(1, from: 20), issue: .activity, to: .random(), in: conversation), "another friend has their own budget")
    }

    @Test func anUnreadableFileThrowsInsteadOfReadingEmpty() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let ledger = FileConversationLedger(file: file)
        await #expect(throws: FileConversationLedger.Unreadable.self) { try await ledger.isRetired(ConversationID()) }
        await #expect(throws: FileConversationLedger.Unreadable.self) { try await ledger.retire(ConversationID()) }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "not json", "never overwritten")
    }

    /// ADR 0021 amendment 13: a failed write latches the ledger closed, so
    /// a retirement it could not record never reads as an open conversation.
    @Test func aFailedWriteLatchesTheLedgerClosed() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "blocked")
        try Data().write(to: blocker)
        let ledger = FileConversationLedger(file: JSONFile(url: blocker.appending(path: "ledger.json")))
        let conversation = ConversationID()
        await #expect(throws: (any Error).self) { try await ledger.retire(conversation) }
        await #expect(throws: (any Error).self) { try await ledger.isRetired(conversation) }
        await #expect(throws: (any Error).self) { try await ledger.reserve(try keywords(1), issue: .activity, to: maya, in: ConversationID()) }

        // And Outbox therefore sends nothing more.
        let transport = RecordingTransport()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), ledger: ledger)
        await #expect(throws: (any Error).self) {
            try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: conversation)
        }
        #expect(await transport.sent.isEmpty)
    }

    /// Outbox enforces the ledger: nothing is sent in a retired
    /// conversation, and a ledger that cannot be read stops every send.
    @Test func outboxSendsNothingInARetiredConversationOrWithoutALedger() async throws {
        let transport = RecordingTransport()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            ledger: FileConversationLedger(file: file))
        let conversation = ConversationID()
        try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: conversation)
        try await outbox.retire(conversation)
        await #expect(throws: OutboxError.conversationRetired) {
            try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: conversation)
        }
        #expect(await transport.sent.count == 1)

        let blocked = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                             ledger: UnavailableConversationLedger())
        await #expect(throws: (any Error).self) {
            try await blocked.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: ConversationID())
        }
        #expect(await transport.sent.count == 1)
    }
}
