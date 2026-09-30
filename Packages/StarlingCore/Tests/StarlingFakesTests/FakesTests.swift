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

    /// Issue #6: the initiator must enforce the peer bound on replies too,
    /// counting raw entries before any deduplication.
    @Test func initiatorEnforcesThePeerBoundOnReplies() async throws {
        let config = try PSIConfiguration(output: .intersection, maxPeerSetSize: 1, maxLocalSetSize: 2)
        let a = try stub.makeSession(role: .initiator, localSet: elements(["a", "b"]), configuration: config)
        guard case .send(let request) = try await a.start() else { Issue.record("no request"); return }
        let hashes = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])["hashes"] as! [String]
        let both = Data(try JSONSerialization.data(withJSONObject: ["hashes": hashes]))
        await #expect(throws: PSIError.peerSetTooLarge(2)) { _ = try await a.handle(both) }

        let b = try stub.makeSession(role: .initiator, localSet: elements(["a"]), configuration: config)
        guard case .send(let request2) = try await b.start() else { Issue.record("no request"); return }
        let one = (try JSONSerialization.jsonObject(with: request2) as! [String: Any])["hashes"] as! [String]
        let repeated = Data(try JSONSerialization.data(withJSONObject: ["hashes": Array(repeating: one[0], count: 336)]))
        await #expect(throws: PSIError.peerSetTooLarge(336)) { _ = try await b.handle(repeated) }
    }

    @Test func initiatorBoundsCardinalityReplies() async throws {
        let config = try PSIConfiguration(output: .cardinality, maxPeerSetSize: 1, maxLocalSetSize: 2)
        let a = try stub.makeSession(role: .initiator, localSet: elements(["a", "b"]), configuration: config)
        _ = try await a.start()
        await #expect(throws: PSIError.peerSetTooLarge(2)) { _ = try await a.handle(Data(#"{"count":2}"#.utf8)) }
    }

    /// Issue #7: this stub uses 32-byte SHA-256 digests; anything else is
    /// malformed, not "no overlap".
    @Test(arguments: [0, 1, 31, 33, 64])
    func responderRejectsMalformedDigestLengths(length: Int) async throws {
        let config = try PSIConfiguration(output: .intersection, maxPeerSetSize: 2, maxLocalSetSize: 2)
        let responder = try stub.makeSession(role: .responder, localSet: elements(["a"]), configuration: config)
        let request: [String: Any] = [
            "salt": Data(repeating: 1, count: 16).base64EncodedString(),
            "hashes": [Data(repeating: 7, count: length).base64EncodedString()],
            "output": "intersection",
        ]
        await #expect(throws: PSIError.malformedMessage) {
            _ = try await responder.handle(try JSONSerialization.data(withJSONObject: request))
        }
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
