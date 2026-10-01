import Foundation
import StarlingCore

/// The secure channel's framing on top of an opaque `Transport` (ADR 0100).
///
/// Every frame starts with one type byte. Handshake frames carry a Noise KK
/// message as-is. Transport frames carry an explicit 8-byte big-endian nonce
/// followed by a Noise transport message (Noise section 11.4). Pairing frames
/// carry pairing traffic for `PairingService`, which runs its own Noise XX.
enum SecureWire {
    enum FrameType: UInt8 {
        case handshake1 = 0x01
        case handshake2 = 0x02
        case transport = 0x03
        case pairing = 0x10
    }

    /// First byte of a transport message's plaintext.
    enum PayloadKind: UInt8 {
        /// Sent by the KK initiator right after message 2 so the responder
        /// knows the session is live and not a replayed message 1.
        case confirm = 0x00
        case data = 0x01
        /// Sent by the KK responder for every confirm it receives, so the
        /// initiator can stop resending and drop its previous session.
        case confirmAck = 0x02
    }

    /// Noise prologue for paired-peer sessions. Mismatched versions fail the handshake.
    static let kkPrologue = Data("Starling secure channel v1".utf8)
    static let nonceLength = 8
    /// type + nonce + kind + tag.
    static let transportOverhead = 1 + nonceLength + 1 + NoiseCipherState.tagLength
    /// A KK handshake message with an empty payload: ephemeral key plus tag.
    static let handshakeLength = NoiseHandshakeState.dhLength + NoiseCipherState.tagLength

    static func frame(_ type: FrameType, _ body: Data) throws -> Frame {
        var bytes = Data(capacity: body.count + 1)
        bytes.append(type.rawValue)
        bytes.append(body)
        return try Frame(bytes)
    }

    static func transportFrame(nonce: UInt64, ciphertext: Data) throws -> Frame {
        var body = Data(capacity: nonceLength + ciphertext.count)
        withUnsafeBytes(of: nonce.bigEndian) { body.append(contentsOf: $0) }
        body.append(ciphertext)
        return try frame(.transport, body)
    }

    /// Splits a frame into its type and body. Unknown types return nil.
    static func parse(_ frame: Frame) -> (FrameType, Data)? {
        guard let first = frame.bytes.first, let type = FrameType(rawValue: first) else { return nil }
        return (type, Data(frame.bytes.dropFirst()))
    }

    /// Splits a transport body into its nonce and ciphertext.
    static func parseTransport(_ body: Data) -> (UInt64, Data)? {
        guard body.count >= nonceLength + 1 + NoiseCipherState.tagLength else { return nil }
        let nonce = body.prefix(nonceLength).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (nonce, Data(body.dropFirst(nonceLength)))
    }
}
