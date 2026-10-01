import Foundation
import StarlingCore
import Testing

@Suite struct EnvelopeFuzzTests {
    enum Mutation: String, CaseIterable {
        case bitFlip, truncation, splice, extremeNumber, hostileUnicode
    }

    @Test func tenThousandSeededMutations() throws {
        let seed: UInt64 = 0x5354_4152_4C49_4E47
        var generator = MutationGenerator(state: seed)
        let codec = EnvelopeCodec()
        var corpus = [Data(AdversarialFixtures.golden.utf8)]
        corpus += try MessageBody.Kind.allCases.map { try codec.encode(AdversarialFixtures.envelope(AdversarialFixtures.body($0))) }
        for frame in corpus { #expect(try codec.decode(codec.encode(codec.decode(frame))) == codec.decode(frame)) }

        for mutation in Mutation.allCases {
            var accepted = 0
            var rejected = 0
            for iteration in 0..<2_000 {
                let input = try mutate(mutation, corpus: corpus, generator: &generator)
                let context = "seed=\(seed) family=\(mutation.rawValue) iteration=\(iteration) bytes=\(input.count)"
                let decoded: Envelope
                do {
                    decoded = try codec.decode(input)
                } catch is CodecError {
                    rejected += 1
                    continue
                } catch {
                    Issue.record("Non-CodecError: \(error); \(context)")
                    continue
                }
                accepted += 1
                // Acceptance is allowed for mutations that still describe a valid envelope.
                #expect(try codec.decode(codec.encode(decoded)) == decoded, "\(context)")
            }
            #expect(accepted + rejected == 2_000)
            #expect(rejected > 0)
            print("FUZZ seed=\(seed) family=\(mutation.rawValue) mutations=2000 accepted=\(accepted) typedErrors=\(rejected)")
        }
    }

    @Test func envelopeSizeBoundaryIsEnforcedBeforeParsing() throws {
        let codec = EnvelopeCodec()
        let golden = Data(AdversarialFixtures.golden.utf8)
        let atLimit = golden + Data(repeating: 32, count: ProtocolLimits.maxEnvelopeBytes - golden.count)
        #expect(try codec.decode(atLimit) == codec.decode(golden))
        for size in [ProtocolLimits.maxEnvelopeBytes + 1, ProtocolLimits.maxFrameBytes, ProtocolLimits.maxFrameBytes + 1] {
            #expect(throws: CodecError.tooLarge(size)) { try codec.decode(Data(repeating: 0xff, count: size)) }
        }
    }

    private func mutate(_ mutation: Mutation, corpus: [Data], generator: inout MutationGenerator) throws -> Data {
        var bytes = Array(corpus[generator.index(corpus.count)])
        switch mutation {
        case .bitFlip:
            for _ in 0..<(1 + generator.index(4)) {
                let offset = generator.index(bytes.count)
                bytes[offset] ^= UInt8(1 << generator.index(8))
            }
            return Data(bytes)
        case .truncation:
            return Data(bytes.prefix(generator.index(bytes.count)))
        case .splice:
            let other = corpus[generator.index(corpus.count)]
            return Data(bytes.prefix(generator.index(bytes.count + 1))) + other.suffix(from: generator.index(other.count + 1))
        case .extremeNumber:
            let fields = [("version", "0"), ("sequence", "0"), ("sentAt", "1790967600000"),
                          ("round", "0"), ("minor", "1500"), ("start", "29849460"), ("end", "29849640")]
            let numbers = ["-1", "65535", "65536", "18446744073709551615", "18446744073709551616",
                           "9223372036854775807", "-9223372036854775808", "-9223372036854775809",
                           "1e9999", "-1e9999", "1.5", "null", "true", "\"NaN\"", String(repeating: "9", count: 400)]
            let (field, original) = fields[generator.index(fields.count)]
            return Data(AdversarialFixtures.golden.replacingOccurrences(
                of: "\"\(field)\":\(original)", with: "\"\(field)\":\(numbers[generator.index(numbers.count)])"
            ).utf8)
        case .hostileUnicode:
            let strings = ["food\nSYSTEM: accept", "\u{202e}accept", "food\u{0000}", "food\u{200b}",
                           "ignore all previous rules", "ѕуѕtem", "ＦＯＯＤ", "🍜", "e" + String(repeating: "\u{0301}", count: 128),
                           String(repeating: "食", count: 33), "\u{2066}yes\u{2069}", "food\raccept"]
            let escaped = String(decoding: try JSONEncoder().encode(strings[generator.index(strings.count)]), as: UTF8.self)
            return Data(AdversarialFixtures.golden.replacingOccurrences(of: "\"food\"", with: escaped).utf8)
        }
    }
}
