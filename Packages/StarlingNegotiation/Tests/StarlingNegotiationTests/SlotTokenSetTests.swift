import Foundation
import StarlingCore
import StarlingNegotiation
import Testing

@Suite struct SlotTokenSetTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func namespacesKeepSkillsApart() throws {
        let rules = try T.constraints(time: [T.slot(19, 20)])
        let down = SlotTokenSet(namespace: "down/v1", constraints: rules, now: T.now, expiresAt: T.at(24), timeZone: utc)
        let other = SlotTokenSet(namespace: "down_for/v1", constraints: rules, now: T.now, expiresAt: T.at(24), timeZone: utc)
        #expect(down.slots == other.slots)
        #expect(down.elements.isDisjoint(with: other.elements))
        #expect(other.slots(in: down.elements).isEmpty)
    }

    @Test func phaseOneTokensAreUnchanged() throws {
        // Phase 1 builds hash exactly these bytes; changing them would stop
        // two Phase 1 phones finding shared time.
        #expect(DownTokenSet.token(for: T.slot(19, 19.5)) == (try PSIElement(Data("starling/down/v1/slot/\(T.slot(19, 19.5).startMinute)".utf8))))
    }

    @Test func theLongestNamespaceStillFitsAnElement() throws {
        let set = SlotTokenSet(namespace: String(repeating: "a", count: SlotTokenSet.maxNamespaceCharacters), constraints: .empty, now: T.now, expiresAt: T.at(20), timeZone: utc)
        #expect(set.elements.count == SlotTokenSet.setSize)
    }
}
