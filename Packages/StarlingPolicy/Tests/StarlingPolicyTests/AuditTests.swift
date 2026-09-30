import Foundation
import StarlingCore
import StarlingPolicy
import Testing

@Suite struct AuditTests {
    @Test(arguments: MessageBody.Kind.allCases)
    func everyBodyHasASummary(kind: MessageBody.Kind) throws {
        let envelope = try Fixtures.envelope(Fixtures.body(kind))
        let completedAt = Timestamp(millisecondsSince1970: 100)
        let entry = AuditEntry(sent: envelope, completedAt: completedAt)
        #expect(entry.message == envelope.id)
        #expect(entry.recipient == envelope.recipient)
        #expect(entry.kind == kind)
        #expect(entry.sentAt == completedAt)
        switch kind {
        case .hello, .psi:
            #expect(entry.items.count == 1)
            #expect(entry.items[0].issue == nil)
            #expect(entry.items[0].valueKind == nil)
        case .reject: #expect(entry.items.isEmpty)
        case .answer:
            #expect(entry.items.count == 1)
            #expect(entry.items[0].issue == nil)
            #expect(entry.items[0].valueKind == .keywords)
        default:
            #expect(entry.items.count == 1)
            #expect(entry.items[0].issue == .activity)
            #expect(entry.items[0].valueKind == .keywords)
        }
    }

    @Test func changingRawValuesDoesNotChangeAuditSummary() throws {
        let id = MessageID()
        let completedAt = Timestamp(millisecondsSince1970: 1)
        let pairs: [(IssueValue, IssueValue)] = [
            (.keywords([try Keyword("private diet")]), .keywords([try Keyword("sushi"), try Keyword("boba")])),
            (.amount(try MoneyAmount(minorUnits: 1575)), .amount(try MoneyAmount(minorUnits: 9000, currency: "EUR"))),
            (.slots([try TimeSlot(startMinute: 100, endMinute: 200)]), .slots([])),
            (.flag(true), .flag(false)), (.count(10), .count(20)),
        ]
        for (first, second) in pairs {
            let a = AuditEntry(sent: try Fixtures.envelope(.query(Query(issue: .activity, candidates: first)), id: id), completedAt: completedAt)
            let b = AuditEntry(sent: try Fixtures.envelope(.query(Query(issue: .activity, candidates: second)), id: id), completedAt: completedAt)
            #expect(a == b)
        }
    }

    @Test func auditStorageIsBoundedAndCanBeCleared() async throws {
        #expect(throws: (any Error).self) { try InMemoryAuditLog(capacity: 0) }
        let log = try InMemoryAuditLog(capacity: 2)
        let entries = try (0..<3).map { index in
            AuditEntry(sent: try Fixtures.envelope(Fixtures.body(.hello)), completedAt: Timestamp(millisecondsSince1970: Int64(index)))
        }
        for entry in entries { await log.append(entry) }
        #expect(await log.entries() == Array(entries.suffix(2)))
        await log.removeAll()
        #expect(await log.entries().isEmpty)
    }
}
