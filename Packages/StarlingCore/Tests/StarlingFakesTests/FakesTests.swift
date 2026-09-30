import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct InsecurePSIStubTests {
    let stub = InsecurePSIStub()

    func elements(_ values: [String]) throws -> Set<PSIElement> {
        Set(try values.map { try PSIElement(Data($0.utf8)) })
    }

    func run(initiator: Set<PSIElement>, responder: Set<PSIElement>, configuration: PSIConfiguration) async throws -> (PSIResult?, PSIResult?) {
        let a = try stub.makeSession(role: .initiator, localSet: initiator, configuration: configuration)
        let b = try stub.makeSession(role: .responder, localSet: responder, configuration: configuration)
        guard case .send(let request) = try await a.start() else { throw PSIError.unexpectedMessage }
        guard case .finish(let reply?, let responderResult) = try await b.handle(request) else { throw PSIError.unexpectedMessage }
        guard case .finish(nil, let initiatorResult) = try await a.handle(reply) else { throw PSIError.unexpectedMessage }
        return (initiatorResult, responderResult)
    }

    @Test func bothSidesLearnTheIntersection() async throws {
        let config = try PSIConfiguration(output: .intersection, maxPeerSetSize: 10, maxLocalSetSize: 10)
        let (a, b) = try await run(initiator: elements(["fri-19", "sat-12", "sat-18"]), responder: elements(["sat-18", "sun-10"]), configuration: config)
        let expected = PSIResult.intersection(try elements(["sat-18"]))
        #expect(a == expected)
        #expect(b == expected)
    }

    @Test func cardinalityModeReturnsOnlyACount() async throws {
        let config = try PSIConfiguration(output: .cardinality, maxPeerSetSize: 10, maxLocalSetSize: 10)
        let (a, b) = try await run(initiator: elements(["x", "y", "z"]), responder: elements(["y", "z"]), configuration: config)
        #expect(a == .cardinality(2))
        #expect(b == .cardinality(2))
    }

    /// Brief 3.9: a peer that submits every possible slot must be refused.
    @Test func responderRejectsOversizedPeerSets() async throws {
        let everySlot = try elements((0..<336).map { "slot-\($0)" })
        let initiator = try stub.makeSession(role: .initiator, localSet: everySlot, configuration: PSIConfiguration(output: .intersection, maxPeerSetSize: 400, maxLocalSetSize: 400))
        let responder = try stub.makeSession(role: .responder, localSet: elements(["slot-7"]), configuration: PSIConfiguration(output: .intersection, maxPeerSetSize: 48, maxLocalSetSize: 48))
        guard case .send(let request) = try await initiator.start() else { Issue.record("no request"); return }
        await #expect(throws: PSIError.peerSetTooLarge(336)) { _ = try await responder.handle(request) }
    }

    @Test func refusesOversizedLocalSets() throws {
        let config = try PSIConfiguration(output: .intersection, maxPeerSetSize: 2, maxLocalSetSize: 2)
        #expect(throws: PSIError.localSetTooLarge(3)) {
            _ = try stub.makeSession(role: .initiator, localSet: elements(["a", "b", "c"]), configuration: config)
        }
    }

    @Test func initiatorRejectsRepliesNamingElementsItNeverSent() async throws {
        let config = try PSIConfiguration(output: .intersection, maxPeerSetSize: 10, maxLocalSetSize: 10)
        let a = try stub.makeSession(role: .initiator, localSet: elements(["a"]), configuration: config)
        _ = try await a.start()
        let forged = Data(#"{"hashes":["AAAA"]}"#.utf8)
        await #expect(throws: PSIError.malformedMessage) { _ = try await a.handle(forged) }
    }

    @Test func isLabeledAsNotPrivate() {
        #expect(stub.descriptor.isPrivate == false)
    }
}

@Suite struct ScriptedAgentModelTests {
    @Test func defaultMatchIsExactOnly() async throws {
        let model = ScriptedAgentModel()
        let result = try await model.match(wanted: [try Keyword("boba"), try Keyword("food")], offered: [try Keyword("boba")])
        #expect(result.value == [KeywordMatch(wanted: try Keyword("boba"), offered: try Keyword("boba"), strength: .equivalent)])
    }

    @Test func unscriptedTasksThrowUnsupported() async throws {
        let model = ScriptedAgentModel()
        let context = InterpretationContext(now: Date(), timeZone: .gmt, issues: [.time])
        await #expect(throws: AgentModelError.unsupported) { _ = try await model.interpret(try OwnerUtterance("free tonight"), context: context) }
    }
}

@Suite struct StaticAvailabilitySourceTests {
    @Test func clipsFreeTimeToTheQueryWindow() async throws {
        let source = StaticAvailabilitySource(kind: .statedIntent, answer: .known(free: [try TimeSlot(startMinute: 0, endMinute: 600)]))
        let answer = try await source.availability(for: AvailabilityQuery(window: TimeSlot(startMinute: 300, endMinute: 900)))
        #expect(answer == .known(free: [try TimeSlot(startMinute: 300, endMinute: 600)]))
    }
}
