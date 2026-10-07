import Foundation

public enum CodecError: Error, Hashable, Sendable {
    case tooLarge(Int)
    case malformed(String)
    case invalid(ValidationError)
    case unsupportedVersion(UInt16)
}

/// Encodes envelopes as sorted-key JSON (protocol versions 0 and 2; 1 is
/// retired, ADR 0020).
///
/// JSON keeps v0 debuggable and close to A2A's JSON messages.
/// Decoding checks the size before parsing, and every nested type validates
/// itself, so a hostile frame fails here or not at all.
public struct EnvelopeCodec: Sendable {
    public static let supportedVersions: Set<UInt16> = [0, 2]

    public init() {}

    public func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch let error as ValidationError {
            throw CodecError.invalid(error)
        }
        guard data.count <= ProtocolLimits.maxEnvelopeBytes else { throw CodecError.tooLarge(data.count) }
        return data
    }

    public func decode(_ data: Data) throws -> Envelope {
        guard data.count <= ProtocolLimits.maxEnvelopeBytes else { throw CodecError.tooLarge(data.count) }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as ValidationError {
            throw CodecError.invalid(error)
        } catch let DecodingError.dataCorrupted(context) {
            // Validation errors thrown inside nested containers can surface
            // wrapped; unwrap them so callers see the real reason.
            if let underlying = context.underlyingError as? ValidationError { throw CodecError.invalid(underlying) }
            throw CodecError.malformed(context.debugDescription)
        } catch {
            throw CodecError.malformed(String(describing: error))
        }
        guard Self.supportedVersions.contains(envelope.version) else {
            throw CodecError.unsupportedVersion(envelope.version)
        }
        return envelope
    }
}
