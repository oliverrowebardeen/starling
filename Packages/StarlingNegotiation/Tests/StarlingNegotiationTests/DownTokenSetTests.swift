import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingNegotiation
import Testing

@Suite struct DownTokenSetTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func slotsAreHalfHoursInsideTheWindowAndPaddedToAFixedSize() throws {
        let rules = try T.constraints(time: [T.slot(19, 21)])
        let set = DownTokenSet(constraints: rules, now: T.now, expiresAt: T.at(24), timeZone: utc)

        #expect(set.slots == [T.slot(19, 19.5), T.slot(19.5, 20), T.slot(20, 20.5), T.slot(20.5, 21)])
        #expect(set.elements.count == DownTokenSet.setSize)
        #expect(set.slots.allSatisfy { set.elements.contains(DownTokenSet.token(for: $0)) })
    }

    @Test func setSizeIsTheSameWhateverTheAvailability() throws {
        let narrow = DownTokenSet(constraints: try T.constraints(time: [T.slot(19, 19.5)]), now: T.now, expiresAt: T.at(24), timeZone: utc)
        let wide = DownTokenSet(constraints: try T.constraints(time: [T.slot(19, 23)]), now: T.now, expiresAt: T.at(24), timeZone: utc)
        #expect(narrow.elements.count == wide.elements.count)
    }

    @Test func slotsStartOnTheNextBoundaryAndEndByExpiry() throws {
        let set = DownTokenSet(constraints: .empty, now: T.at(19.2), expiresAt: T.at(21.2), timeZone: utc)
        #expect(set.slots.first == T.slot(19.5, 20))
        #expect(set.slots.last == T.slot(20.5, 21))
    }

    @Test func slotsHonorTheDailyWindowInTheOwnersTimeZone() throws {
        // 19:00 UTC is 12:00 in Los Angeles (PDT, UTC-7). "No plans before 13:00" local.
        let rules = try ConstraintSet([.time: [try Constraint(.dailyWindow(from: 13 * 60, to: 1440))]])
        let set = DownTokenSet(constraints: rules, now: T.now, expiresAt: T.at(22), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(set.slots.first == T.slot(20, 20.5))
    }

    @Test func realSlotsAreCappedAtTheSetSize() throws {
        let set = DownTokenSet(constraints: .empty, now: T.now, expiresAt: T.at(19 + 48), timeZone: utc)
        #expect(set.slots.count == DownTokenSet.setSize)
        #expect(set.elements.count == DownTokenSet.setSize)
    }

    @Test func noAvailableTimeGivesNoSlots() throws {
        let set = DownTokenSet(constraints: try T.constraints(time: [T.slot(10, 11)]), now: T.now, expiresAt: T.at(24), timeZone: utc)
        #expect(set.slots.isEmpty)
    }

    @Test func tokensFitAPSIElementAndMapBack() throws {
        let set = DownTokenSet(constraints: try T.constraints(time: [T.slot(19, 20)]), now: T.now, expiresAt: T.at(24), timeZone: utc)
        let stranger = try PSIElement(Data("starling/down/v1/slot/1".utf8))
        let found = set.slots(in: [DownTokenSet.token(for: T.slot(19.5, 20)), stranger])
        #expect(found == [T.slot(19.5, 20)])
    }

    @Test func psiOverTheStubFindsExactlyTheSharedSlots() async throws {
        let mine = DownTokenSet(constraints: try T.constraints(time: [T.slot(19, 21)]), now: T.now, expiresAt: T.at(24), timeZone: utc)
        let theirs = DownTokenSet(constraints: try T.constraints(time: [T.slot(20, 23)]), now: T.now, expiresAt: T.at(24), timeZone: utc)
        let configuration = try DownTokenSet.psiConfiguration()
        let initiator = try InsecurePSIStub().makeSession(role: .initiator, localSet: mine.elements, configuration: configuration)
        let responder = try InsecurePSIStub().makeSession(role: .responder, localSet: theirs.elements, configuration: configuration)

        guard case .send(let request) = try await initiator.start(),
              case .finish(let reply?, _) = try await responder.handle(request),
              case .finish(nil, .intersection(let shared)?) = try await initiator.handle(reply)
        else { Issue.record("unexpected PSI steps"); return }
        #expect(mine.slots(in: shared) == [T.slot(20, 20.5), T.slot(20.5, 21)])
    }
}
