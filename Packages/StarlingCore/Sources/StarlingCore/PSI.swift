import Foundation

/// One item in a PSI set: a canonical byte encoding of a slot, keyword, or yes/no
/// token. Callers must encode values identically on both sides.
public struct PSIElement: Hashable, Sendable {
    public static let maxByteCount = 64
    public let bytes: Data

    public init(_ bytes: Data) throws {
        guard (1...Self.maxByteCount).contains(bytes.count) else {
            throw ValidationError("PSIElement", "must be 1-\(Self.maxByteCount) bytes")
        }
        self.bytes = bytes
    }
}

public enum PSIOutput: String, Hashable, Sendable, Codable {
    /// Learn which elements are shared.
    case intersection
    /// Learn only how many are shared.
    case cardinality
}

public enum PSIRole: String, Hashable, Sendable, Codable {
    case initiator, responder
}

public struct PSIConfiguration: Hashable, Sendable {
    public let output: PSIOutput
    /// Reject a run if the peer's set is larger than this. Set sizes are
    /// visible in DH-based PSI, and a peer that submits every possible value
    /// (for example all 336 half-hour slots in a week) would learn our whole
    /// set (brief 3.9). Pick the smallest bound the feature allows.
    public let maxPeerSetSize: Int
    public let maxLocalSetSize: Int

    public init(output: PSIOutput, maxPeerSetSize: Int, maxLocalSetSize: Int) throws {
        guard maxPeerSetSize > 0, maxLocalSetSize > 0 else {
            throw ValidationError("PSIConfiguration", "set size bounds must be positive")
        }
        self.output = output
        self.maxPeerSetSize = maxPeerSetSize
        self.maxLocalSetSize = maxLocalSetSize
    }
}

public enum PSIResult: Hashable, Sendable {
    case intersection(Set<PSIElement>)
    case cardinality(Int)
}

public enum PSIStep: Hashable, Sendable {
    /// Send this payload to the peer and wait for its reply.
    case send(Data)
    /// The run is over. Send `payload` if present. `result` is nil for a role
    /// that learns nothing in this protocol.
    case finish(payload: Data?, result: PSIResult?)
}

public enum PSIError: Error, Hashable, Sendable {
    case localSetTooLarge(Int)
    case peerSetTooLarge(Int)
    case malformedMessage
    case unexpectedMessage
    case unsupportedOutput(PSIOutput)
}

/// One PSI run. Payloads travel in `MessageBody.psi` frames.
public protocol PSISession: Sendable {
    /// The initiator's first step. Responders return `.send` or `.finish`
    /// only from `handle`.
    func start() async throws -> PSIStep
    func handle(_ payload: Data) async throws -> PSIStep
}

public struct PSIProviderDescriptor: Hashable, Sendable {
    public let name: String
    /// False for development stubs. The policy layer and UI must treat a
    /// non-private provider as disclosing the whole set.
    public let isPrivate: Bool

    public init(name: String, isPrivate: Bool) {
        self.name = name
        self.isPrivate = isPrivate
    }
}

/// Private set intersection. The real implementation comes from Nightjar;
/// `StarlingFakes.InsecurePSIStub` stands in until then.
public protocol PSIProvider: Sendable {
    var descriptor: PSIProviderDescriptor { get }
    func makeSession(role: PSIRole, localSet: Set<PSIElement>, configuration: PSIConfiguration) throws -> any PSISession
}
