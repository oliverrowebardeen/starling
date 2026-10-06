import Foundation
import StarlingCore
import StarlingFakes
import Testing

/// Exercise the public contract so another PSIProvider can reuse this suite.
@Suite struct PSIAbuseTests {
    let provider: any PSIProvider = InsecurePSIStub()

    struct Request: Codable { let salt: Data; let hashes: [Data]; let output: PSIOutput }
    struct Reply: Codable { let hashes: [Data]?; let count: Int? }

    func configuration(_ output: PSIOutput = .intersection, peer: Int = 2, local: Int = 2) throws -> PSIConfiguration {
        try PSIConfiguration(output: output, maxPeerSetSize: peer, maxLocalSetSize: local)
    }

    func elements(_ count: Int) throws -> Set<PSIElement> {
        Set(try (0..<count).map { try PSIElement(Data("slot-\($0)".utf8)) })
    }

    func request(hashes: [Data], salt: Data = Data(repeating: 0, count: 16), output: PSIOutput = .intersection) throws -> Data {
        try JSONEncoder().encode(Request(salt: salt, hashes: hashes, output: output))
    }

    @Test func insecureProviderDeclaresDisclosure() { #expect(!provider.descriptor.isPrivate) }

    @Test(arguments: [PSIRole.initiator, .responder])
    func oversizedLocalSetIsRejected(role: PSIRole) throws {
        #expect(throws: PSIError.localSetTooLarge(336)) {
            try provider.makeSession(role: role, localSet: elements(336), configuration: configuration())
        }
    }

    @Test(arguments: [PSIOutput.intersection, .cardinality])
    func oversizedPeerRequestsAreRejected(output: PSIOutput) async throws {
        let session = try provider.makeSession(role: .responder, localSet: elements(2), configuration: configuration(output))
        // Repeating a digest must not bypass the wire-list cap by deduplication.
        let payload = try request(hashes: Array(repeating: Data(repeating: 1, count: 32), count: 336), output: output)
        await #expect(throws: PSIError.peerSetTooLarge(336)) { try await session.handle(payload) }
    }

    @Test(arguments: [PSIOutput.intersection, .cardinality])
    func boundaryAndEmptySetsComplete(output: PSIOutput) async throws {
        for size in [0, 2] {
            let local = try elements(size)
            let config = try configuration(output)
            let initiator = try provider.makeSession(role: .initiator, localSet: local, configuration: config)
            let responder = try provider.makeSession(role: .responder, localSet: local, configuration: config)
            guard case .send(let first) = try await initiator.start(),
                  case .finish(let reply?, let result) = try await responder.handle(first) else {
                Issue.record("Expected a two-step exchange")
                return
            }
            let expected: PSIResult = output == .intersection ? .intersection(local) : .cardinality(size)
            #expect(result == expected)
            #expect(try await initiator.handle(reply) == .finish(payload: nil, result: expected))
            await #expect(throws: PSIError.unexpectedMessage) { try await initiator.handle(reply) }
            await #expect(throws: PSIError.unexpectedMessage) { try await responder.handle(first) }
            await #expect(throws: PSIError.unexpectedMessage) { try await initiator.start() }
            if output == .cardinality {
                #expect(try JSONDecoder().decode(Reply.self, from: reply).hashes == nil)
            }
        }
    }

    @Test func outOfOrderStepsAreRejected() async throws {
        let config = try configuration()
        let initiator = try provider.makeSession(role: .initiator, localSet: elements(1), configuration: config)
        let responder = try provider.makeSession(role: .responder, localSet: elements(1), configuration: config)
        let reply = try JSONEncoder().encode(Reply(hashes: [], count: nil))
        await #expect(throws: PSIError.unexpectedMessage) { try await initiator.handle(reply) }
        await #expect(throws: PSIError.unexpectedMessage) { try await responder.start() }
        _ = try await initiator.start()
        await #expect(throws: PSIError.unexpectedMessage) { try await initiator.start() }
        await #expect(throws: PSIError.malformedMessage) { try await responder.handle(reply) }
    }

    @Test func malformedRequestsHaveTypedErrors() async throws {
        let malformed = [Data(), Data("{".utf8), Data("{}".utf8), Data([0xff, 0x00]),
                         try request(hashes: [], salt: Data()), try request(hashes: [], salt: Data(repeating: 0, count: 17)),
                         Data(#"{"salt":"not base64","hashes":[],"output":"intersection"}"#.utf8)]
        for payload in malformed {
            let session = try provider.makeSession(role: .responder, localSet: elements(1), configuration: configuration())
            await #expect(throws: PSIError.malformedMessage) { try await session.handle(payload) }
        }
    }

    @Test func mismatchedOutputIsRejected() async throws {
        let session = try provider.makeSession(role: .responder, localSet: elements(1), configuration: configuration())
        let payload = try request(hashes: [], output: .cardinality)
        await #expect(throws: PSIError.unsupportedOutput(.cardinality)) { try await session.handle(payload) }
    }

    @Test func malformedAndOversizedRepliesHaveTypedErrors() async throws {
        for output in [PSIOutput.intersection, .cardinality] {
            let malformed: [(Data, PSIError)] = [
                (Data(), .malformedMessage), (Data("{}".utf8), .malformedMessage), (Data([0xff]), .malformedMessage),
                (try JSONEncoder().encode(Reply(hashes: [Data(repeating: 0, count: 32)], count: -1)), .malformedMessage),
                (try JSONEncoder().encode(Reply(hashes: [Data()], count: Int.max)),
                 output == .cardinality ? .peerSetTooLarge(Int.max) : .malformedMessage),
            ]
            for (payload, expected) in malformed {
                let session = try provider.makeSession(role: .initiator, localSet: elements(1), configuration: configuration(output))
                _ = try await session.start()
                await #expect(throws: expected) { try await session.handle(payload) }
            }
        }
    }

    @Test(arguments: [0, 1, 31, 33, 64])
    func malformedDigestLengthsAreRejected(length: Int) async throws {
        let session = try provider.makeSession(role: .responder, localSet: elements(1), configuration: configuration())
        let payload = try request(hashes: [Data(repeating: 0, count: length)])
        // Regression: #7
        await #expect(throws: PSIError.malformedMessage) { try await session.handle(payload) }
    }

    @Test(arguments: [PSIOutput.intersection, .cardinality])
    func initiatorEnforcesPeerBoundOnReply(output: PSIOutput) async throws {
        let session = try provider.makeSession(role: .initiator, localSet: elements(2), configuration: configuration(output, peer: 1))
        guard case .send(let first) = try await session.start() else { Issue.record("Expected request"); return }
        let sent = try JSONDecoder().decode(Request.self, from: first)
        let payload = try JSONEncoder().encode(Reply(hashes: output == .intersection ? sent.hashes : nil, count: output == .cardinality ? 2 : nil))
        // Regression: #6
        await #expect(throws: PSIError.peerSetTooLarge(2)) { try await session.handle(payload) }
    }

    @Test func repeatedReplyHashesCannotBypassPeerBound() async throws {
        let session = try provider.makeSession(role: .initiator, localSet: elements(1), configuration: configuration(peer: 1))
        guard case .send(let first) = try await session.start() else { Issue.record("Expected request"); return }
        let sent = try JSONDecoder().decode(Request.self, from: first)
        let payload = try JSONEncoder().encode(Reply(hashes: Array(repeating: sent.hashes[0], count: 336), count: nil))
        // Regression: #6
        await #expect(throws: PSIError.peerSetTooLarge(336)) { try await session.handle(payload) }
    }
}
