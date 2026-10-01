import CryptoKit
import Foundation

/// Handshake tokens from Noise revision 34, section 7 (no PSK modifiers).
enum NoiseToken: Sendable {
    case e, s, ee, es, se, ss
}

/// The two handshake patterns Starling uses, copied from section 7.5. Only
/// static-key pre-messages occur in them.
struct NoisePattern: Sendable {
    let name: String
    let initiatorPreMessage: [NoiseToken]
    let responderPreMessage: [NoiseToken]
    let messages: [[NoiseToken]]

    /// Pairing: neither side knows the other's static key yet.
    static let xx = NoisePattern(
        name: "XX",
        initiatorPreMessage: [],
        responderPreMessage: [],
        messages: [[.e], [.e, .ee, .s, .es], [.s, .se]]
    )

    /// Paired peers: both static keys were pinned at pairing.
    static let kk = NoisePattern(
        name: "KK",
        initiatorPreMessage: [.s],
        responderPreMessage: [.s],
        messages: [[.e, .es, .ss], [.e, .ee, .se]]
    )

    /// Section 8, with the 25519, ChaChaPoly, and SHA256 functions (section 12).
    var protocolName: String { "Noise_\(name)_25519_ChaChaPoly_SHA256" }

    var needsRemoteStaticUpFront: Bool { initiatorPreMessage.contains(.s) || responderPreMessage.contains(.s) }
}

/// The result of a finished handshake: transport keys, the handshake hash for
/// channel binding (section 11.2), and the authenticated remote static key.
/// The `HandshakeState` that produced it is discarded, per section 5.
struct NoiseSession: Sendable {
    var send: NoiseCipherState
    var receive: NoiseCipherState
    let handshakeHash: Data
    let remoteStatic: X25519PublicKey
}

/// Noise revision 34, section 5.3, for the XX and KK patterns over
/// 25519, ChaChaPoly, and SHA256. No deviations from the spec: anything
/// Starling adds (framing, explicit nonces, confirmation) lives outside.
struct NoiseHandshakeState: Sendable {
    static let dhLength = 32
    /// Section 3: "the maximum Noise message length" is 65535 bytes.
    static let maxMessageLength = 65_535

    private var symmetric: NoiseSymmetricState
    private let initiator: Bool
    private let localStatic: X25519PrivateKey
    private var localEphemeral: X25519PrivateKey?
    private var remoteStatic: X25519PublicKey?
    private var remoteEphemeral: X25519PublicKey?
    private var remaining: [[NoiseToken]]
    private var completedMessages = 0
    /// GENERATE_KEYPAIR() for ephemeral keys. Tests inject the vector keys.
    private let generateEphemeral: @Sendable () -> X25519PrivateKey
    private var transport: (NoiseCipherState, NoiseCipherState)?

    /// Initialize(handshake_pattern, initiator, prologue, s, e, rs, re).
    /// `e` and `re` are always empty for XX and KK.
    init(
        pattern: NoisePattern,
        initiator: Bool,
        prologue: Data,
        localStatic: X25519PrivateKey,
        remoteStatic: X25519PublicKey?,
        ephemeral generateEphemeral: @escaping @Sendable () -> X25519PrivateKey = { X25519PrivateKey() }
    ) throws {
        guard pattern.needsRemoteStaticUpFront == (remoteStatic != nil) else {
            throw NoiseError.invalidConfiguration
        }
        symmetric = NoiseSymmetricState(protocolName: Data(pattern.protocolName.utf8))
        symmetric.mixHash(prologue)
        self.initiator = initiator
        self.localStatic = localStatic
        self.remoteStatic = remoteStatic
        self.generateEphemeral = generateEphemeral
        remaining = pattern.messages

        // Pre-messages: the initiator's keys are hashed first. Only "s" occurs.
        let initiatorStatic = initiator ? localStatic.publicKey : remoteStatic
        let responderStatic = initiator ? remoteStatic : localStatic.publicKey
        for token in pattern.initiatorPreMessage {
            guard token == .s, let key = initiatorStatic else { throw NoiseError.invalidConfiguration }
            symmetric.mixHash(key.rawRepresentation)
        }
        for token in pattern.responderPreMessage {
            guard token == .s, let key = responderStatic else { throw NoiseError.invalidConfiguration }
            symmetric.mixHash(key.rawRepresentation)
        }
    }

    var isComplete: Bool { transport != nil }

    /// Whether the next handshake message is ours to write.
    var isOurTurn: Bool { !remaining.isEmpty && completedMessages.isMultiple(of: 2) == initiator }

    /// WriteMessage(payload, message_buffer).
    mutating func writeMessage(payload: Data) throws -> Data {
        guard isOurTurn else { throw NoiseError.malformedMessage }
        let tokens = remaining.removeFirst()
        completedMessages += 1
        var buffer = Data()
        for token in tokens {
            switch token {
            case .e:
                guard localEphemeral == nil else { throw NoiseError.invalidConfiguration }
                let ephemeral = generateEphemeral()
                localEphemeral = ephemeral
                buffer += ephemeral.publicKey.rawRepresentation
                symmetric.mixHash(ephemeral.publicKey.rawRepresentation)
            case .s:
                buffer += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
            default:
                try mixDH(token)
            }
        }
        buffer += try symmetric.encryptAndHash(payload)
        guard buffer.count <= Self.maxMessageLength else { throw NoiseError.malformedMessage }
        finishIfDone()
        return buffer
    }

    /// ReadMessage(message, payload_buffer).
    mutating func readMessage(_ message: Data) throws -> Data {
        guard !remaining.isEmpty, !isOurTurn, message.count <= Self.maxMessageLength else {
            throw NoiseError.malformedMessage
        }
        let tokens = remaining.removeFirst()
        completedMessages += 1
        var cursor = message.startIndex
        func take(_ count: Int) throws -> Data {
            guard message.endIndex - cursor >= count else { throw NoiseError.malformedMessage }
            defer { cursor += count }
            return Data(message[cursor..<cursor + count])
        }
        for token in tokens {
            switch token {
            case .e:
                guard remoteEphemeral == nil else { throw NoiseError.invalidConfiguration }
                let bytes = try take(Self.dhLength)
                remoteEphemeral = try Self.publicKey(bytes)
                symmetric.mixHash(bytes)
            case .s:
                guard remoteStatic == nil else { throw NoiseError.invalidConfiguration }
                let length = Self.dhLength + (symmetric.cipher.hasKey ? NoiseCipherState.tagLength : 0)
                remoteStatic = try Self.publicKey(symmetric.decryptAndHash(take(length)))
            default:
                try mixDH(token)
            }
        }
        let payload = try symmetric.decryptAndHash(Data(message[cursor...]))
        finishIfDone()
        return payload
    }

    /// The transport keys, once the last handshake message is processed.
    func session() throws -> NoiseSession {
        guard let (initiatorToResponder, responderToInitiator) = transport, let remoteStatic else {
            throw NoiseError.invalidConfiguration
        }
        return NoiseSession(
            send: initiator ? initiatorToResponder : responderToInitiator,
            receive: initiator ? responderToInitiator : initiatorToResponder,
            handshakeHash: symmetric.handshakeHash,
            remoteStatic: remoteStatic
        )
    }

    private mutating func finishIfDone() {
        if remaining.isEmpty { transport = symmetric.split() }
    }

    private mutating func mixDH(_ token: NoiseToken) throws {
        let (local, remote): (X25519PrivateKey?, X25519PublicKey?) = switch token {
        case .ee: (localEphemeral, remoteEphemeral)
        case .ss: (localStatic, remoteStatic)
        // "es": DH(e, rs) if initiator, DH(s, re) if responder.
        case .es: initiator ? (localEphemeral, remoteStatic) : (localStatic, remoteEphemeral)
        // "se": DH(s, re) if initiator, DH(e, rs) if responder.
        case .se: initiator ? (localStatic, remoteEphemeral) : (localEphemeral, remoteStatic)
        case .e, .s: (nil, nil)
        }
        guard let local, let remote else { throw NoiseError.invalidConfiguration }
        symmetric.mixKey(try Self.dh(local, remote))
    }

    /// Section 12.1. CryptoKit signals an error for inputs that produce an
    /// all-zeros output, which the spec allows; the handshake then fails.
    static func dh(_ privateKey: X25519PrivateKey, _ publicKey: X25519PublicKey) throws -> Data {
        do {
            return try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        } catch {
            throw NoiseError.invalidKey
        }
    }

    private static func publicKey(_ bytes: Data) throws -> X25519PublicKey {
        do {
            return try X25519PublicKey(rawRepresentation: bytes)
        } catch {
            throw NoiseError.invalidKey
        }
    }
}
