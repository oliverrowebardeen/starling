import CryptoKit
import Foundation
@testable import StarlingIdentity
import Testing

/// Published Noise revision 34 test vectors for the two protocols Starling
/// uses (ADR 0003 care requirement 2). Sources and licenses: Vectors/README.md.
@Suite struct NoiseVectorTests {
    struct VectorFile: Decodable { let vectors: [Vector] }

    struct Vector: Decodable {
        struct Message: Decodable { let payload: String; let ciphertext: String }

        let protocol_name: String
        let init_prologue: String
        let init_static: String?
        let init_ephemeral: String
        let init_remote_static: String?
        let resp_prologue: String
        let resp_static: String?
        let resp_ephemeral: String
        let resp_remote_static: String?
        let handshake_hash: String?
        let messages: [Message]
    }

    static let files = ["cacophony-xx-kk", "snow-xx-kk"]

    static func load(_ name: String) throws -> [Vector] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).vectors
    }

    @Test(arguments: files) func eachFileHasBothProtocols(file: String) throws {
        let names = Set(try Self.load(file).map(\.protocol_name))
        #expect(names == ["Noise_XX_25519_ChaChaPoly_SHA256", "Noise_KK_25519_ChaChaPoly_SHA256"])
    }

    @Test(arguments: files) func vectorsReproduceExactly(file: String) throws {
        for vector in try Self.load(file) {
            try run(vector)
        }
    }

    private func run(_ vector: Vector) throws {
        let pattern: NoisePattern = switch vector.protocol_name {
        case "Noise_XX_25519_ChaChaPoly_SHA256": .xx
        case "Noise_KK_25519_ChaChaPoly_SHA256": .kk
        default: throw ValidationFailure("unexpected protocol \(vector.protocol_name)")
        }
        #expect(pattern.protocolName == vector.protocol_name)

        var initiator = try NoiseHandshakeState(
            pattern: pattern, initiator: true, prologue: hex(vector.init_prologue),
            localStatic: privateKey(try #require(vector.init_static)),
            remoteStatic: try vector.init_remote_static.map(publicKey),
            ephemeral: { try! privateKey(vector.init_ephemeral) }
        )
        var responder = try NoiseHandshakeState(
            pattern: pattern, initiator: false, prologue: hex(vector.resp_prologue),
            localStatic: privateKey(try #require(vector.resp_static)),
            remoteStatic: try vector.resp_remote_static.map(publicKey),
            ephemeral: { try! privateKey(vector.resp_ephemeral) }
        )

        var initiatorSession: NoiseSession?
        var responderSession: NoiseSession?
        for (index, message) in vector.messages.enumerated() {
            let fromInitiator = index.isMultiple(of: 2)
            let payload = try hex(message.payload)
            let expected = try hex(message.ciphertext)

            if var sending = fromInitiator ? initiatorSession : responderSession,
               var receiving = fromInitiator ? responderSession : initiatorSession {
                // Transport phase.
                let ciphertext = try sending.send.encrypt(ad: Data(), plaintext: payload)
                #expect(ciphertext == expected, "\(vector.protocol_name) transport message \(index)")
                #expect(try receiving.receive.decrypt(ad: Data(), ciphertext: ciphertext) == payload)
                if fromInitiator { initiatorSession = sending; responderSession = receiving }
                else { responderSession = sending; initiatorSession = receiving }
                continue
            }

            let ciphertext = fromInitiator
                ? try initiator.writeMessage(payload: payload)
                : try responder.writeMessage(payload: payload)
            #expect(ciphertext == expected, "\(vector.protocol_name) handshake message \(index)")
            let read = fromInitiator
                ? try responder.readMessage(ciphertext)
                : try initiator.readMessage(ciphertext)
            #expect(read == payload)

            if initiator.isComplete, responder.isComplete {
                initiatorSession = try initiator.session()
                responderSession = try responder.session()
            }
        }

        let initiatorResult = try #require(initiatorSession)
        let responderResult = try #require(responderSession)
        #expect(initiatorResult.handshakeHash == responderResult.handshakeHash)
        if let hash = vector.handshake_hash {
            #expect(initiatorResult.handshakeHash == (try hex(hash)))
        }
        #expect(initiatorResult.remoteStatic.rawRepresentation == (try privateKey(vector.resp_static!)).publicKey.rawRepresentation)
        #expect(responderResult.remoteStatic.rawRepresentation == (try privateKey(vector.init_static!)).publicKey.rawRepresentation)
    }
}

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func hex(_ string: String) throws -> Data {
    let digits = Array(string.utf8)
    guard digits.count.isMultiple(of: 2) else { throw ValidationFailure("odd hex length") }
    var data = Data(capacity: digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
        guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else {
            throw ValidationFailure("invalid hex")
        }
        data.append(byte)
    }
    return data
}

func privateKey(_ string: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(string))
}

func publicKey(_ string: String) throws -> Curve25519.KeyAgreement.PublicKey {
    try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hex(string))
}
