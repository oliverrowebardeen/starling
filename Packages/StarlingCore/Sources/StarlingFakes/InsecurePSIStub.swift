import CryptoKit
import Foundation
import StarlingCore

/// **INSECURE. Development only.** A stand-in for Nightjar's PSI.
///
/// The initiator sends salted SHA-256 hashes of its whole set. Anyone can
/// brute-force small domains (time slots, yes/no, short keywords) from those
/// hashes, so this reveals the initiator's set to the responder. It exists so
/// mutual-reveal logic can be built and tested before real PSI lands.
/// `descriptor.isPrivate` is false; policy and UI must treat it that way.
///
/// It does enforce the set-size limits a real provider must enforce.
public struct InsecurePSIStub: PSIProvider {
    public let descriptor = PSIProviderDescriptor(name: "insecure-stub", isPrivate: false)

    public init() {}

    public func makeSession(role: PSIRole, localSet: Set<PSIElement>, configuration: PSIConfiguration) throws -> any PSISession {
        guard localSet.count <= configuration.maxLocalSetSize else { throw PSIError.localSetTooLarge(localSet.count) }
        return InsecurePSISession(role: role, localSet: localSet, configuration: configuration)
    }
}

actor InsecurePSISession: PSISession {
    private struct Request: Codable { let salt: Data; let hashes: [Data]; let output: PSIOutput }
    private struct Reply: Codable { let hashes: [Data]?; let count: Int? }

    /// SHA-256 digest length; any other length is malformed, not "no overlap".
    static let digestLength = 32

    private let role: PSIRole
    private let localSet: Set<PSIElement>
    private let configuration: PSIConfiguration
    private var salt: Data?
    private var finished = false

    init(role: PSIRole, localSet: Set<PSIElement>, configuration: PSIConfiguration) {
        self.role = role
        self.localSet = localSet
        self.configuration = configuration
    }

    func start() async throws -> PSIStep {
        guard role == .initiator, salt == nil, !finished else { throw PSIError.unexpectedMessage }
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        self.salt = salt
        let request = Request(salt: salt, hashes: localSet.map { Self.hash($0, salt: salt) }.sorted { $0.lexicographicallyPrecedes($1) }, output: configuration.output)
        return .send(try JSONEncoder().encode(request))
    }

    func handle(_ payload: Data) async throws -> PSIStep {
        guard !finished else { throw PSIError.unexpectedMessage }
        switch role {
        case .responder: return try respond(to: payload)
        case .initiator: return try complete(with: payload)
        }
    }

    private func respond(to payload: Data) throws -> PSIStep {
        guard let request = try? JSONDecoder().decode(Request.self, from: payload), request.salt.count == 16 else {
            throw PSIError.malformedMessage
        }
        guard request.hashes.count <= configuration.maxPeerSetSize else { throw PSIError.peerSetTooLarge(request.hashes.count) }
        guard request.hashes.allSatisfy({ $0.count == Self.digestLength }) else { throw PSIError.malformedMessage }
        guard request.output == configuration.output else { throw PSIError.unsupportedOutput(request.output) }
        let peerHashes = Set(request.hashes)
        let shared = localSet.filter { peerHashes.contains(Self.hash($0, salt: request.salt)) }
        finished = true
        switch configuration.output {
        case .intersection:
            let reply = Reply(hashes: shared.map { Self.hash($0, salt: request.salt) }, count: nil)
            return .finish(payload: try JSONEncoder().encode(reply), result: .intersection(shared))
        case .cardinality:
            let reply = Reply(hashes: nil, count: shared.count)
            return .finish(payload: try JSONEncoder().encode(reply), result: .cardinality(shared.count))
        }
    }

    private func complete(with payload: Data) throws -> PSIStep {
        guard let salt else { throw PSIError.unexpectedMessage }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: payload) else { throw PSIError.malformedMessage }
        finished = true
        switch configuration.output {
        case .intersection:
            guard let hashes = reply.hashes else { throw PSIError.malformedMessage }
            // Count raw entries before deduplication: the intersection can
            // never be larger than the peer's permitted set.
            guard hashes.count <= configuration.maxPeerSetSize else { throw PSIError.peerSetTooLarge(hashes.count) }
            guard hashes.allSatisfy({ $0.count == Self.digestLength }), Set(hashes).count == hashes.count else {
                throw PSIError.malformedMessage
            }
            let byHash = Dictionary(uniqueKeysWithValues: localSet.map { (Self.hash($0, salt: salt), $0) })
            var shared = Set<PSIElement>()
            for hash in hashes {
                // A reply naming something we never sent is malformed.
                guard let element = byHash[hash] else { throw PSIError.malformedMessage }
                shared.insert(element)
            }
            return .finish(payload: nil, result: .intersection(shared))
        case .cardinality:
            guard let count = reply.count, count >= 0 else { throw PSIError.malformedMessage }
            guard count <= configuration.maxPeerSetSize else { throw PSIError.peerSetTooLarge(count) }
            guard count <= localSet.count else { throw PSIError.malformedMessage }
            return .finish(payload: nil, result: .cardinality(count))
        }
    }

    private static func hash(_ element: PSIElement, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + element.bytes))
    }
}
