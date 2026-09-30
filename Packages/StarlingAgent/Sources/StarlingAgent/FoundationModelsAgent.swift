import Foundation
import FoundationModels
import StarlingCore

/// `AgentModel` backed by Apple's on-device model through FoundationModels.
///
/// Every call runs in a fresh `LanguageModelSession` with greedy sampling, so
/// each round's cost is flat and measurements are reproducible (ADR 0002).
public struct FoundationModelsAgent: AgentModel {
    /// Fallback context size when the SDK cannot report one (pre-26.4 SDKs).
    /// This is the documented floor (TN3193), not an assumption about the device.
    public static let fallbackContextSize = 4096

    /// True when this build can call `tokenCount(for:)` (26.4+ SDK).
    public static var canCountTokens: Bool {
        #if compiler(>=6.3)
        if #available(iOS 26.4, macOS 26.4, *) { return true }
        #endif
        return false
    }

    private let model: SystemLanguageModel
    private let timeZone: TimeZone
    private let estimateWhenUncountable: Bool

    /// - Parameter estimateWhenUncountable: When the SDK cannot count tokens,
    ///   report a characters/3.5 estimate instead of nil. For the bench only;
    ///   estimates are labeled as such in its report.
    public init(model: SystemLanguageModel = .default, timeZone: TimeZone = .current, estimateWhenUncountable: Bool = false) {
        self.model = model
        self.timeZone = timeZone
        self.estimateWhenUncountable = estimateWhenUncountable
    }

    public var descriptor: ModelDescriptor {
        ModelDescriptor(identifier: "apple.system", locality: .onDevice, contextSize: contextSize)
    }

    public var contextSize: Int {
        #if compiler(>=6.3)
        if #available(iOS 26.4, macOS 26.4, *) { return model.contextSize }
        #endif
        return Self.fallbackContextSize
    }

    /// Which on-device model backs this instance (`core3` or `coreAdvanced3`),
    /// when the SDK can say. iOS 27 and later.
    public var variantName: String? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) { return String(describing: model.variant.displayName) }
        #endif
        return nil
    }

    public func interpret(_ utterance: OwnerUtterance, context: InterpretationContext) async throws -> ModelResult<OwnerRules> {
        let prompt = PromptRenderer.interpret(utterance, context: context)
        let (output, usage, latency) = try await generate(RulesOutput.self, instructions: PromptRenderer.interpretInstructions, prompt: prompt)
        return ModelResult(value: try OutputMapping.rules(output.raw, context: context), usage: usage, latency: latency)
    }

    public func match(wanted: [Keyword], offered: [Keyword]) async throws -> ModelResult<[KeywordMatch]> {
        guard !wanted.isEmpty, !offered.isEmpty else { return ModelResult(value: [], usage: nil, latency: .zero) }
        let prompt = PromptRenderer.match(wanted: wanted, offered: offered)
        let (output, usage, latency) = try await generate(MatchOutput.self, instructions: PromptRenderer.matchInstructions, prompt: prompt)
        return ModelResult(value: try OutputMapping.matches(output.raw, wanted: wanted, offered: offered), usage: usage, latency: latency)
    }

    public func decide(_ context: NegotiationContext) async throws -> ModelResult<NegotiationMove> {
        let prompt = PromptRenderer.decide(context, timeZone: timeZone)
        let (output, usage, latency) = try await generate(MoveOutput.self, instructions: PromptRenderer.decideInstructions, prompt: prompt.text)
        return ModelResult(value: try OutputMapping.move(output.raw, prompt: prompt, proposal: context.proposal), usage: usage, latency: latency)
    }

    // MARK: - Generation

    private func generate<Output: Generable>(
        _ type: Output.Type,
        instructions: String,
        prompt: String
    ) async throws -> (Output, TokenUsage?, Duration) {
        if case .unavailable(let reason) = model.availability {
            throw AgentModelError.unavailable(reason: String(describing: reason))
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let clock = ContinuousClock()
        let start = clock.now
        let response: LanguageModelSession.Response<Output>
        do {
            response = try await session.respond(to: prompt, generating: type, options: GenerationOptions(sampling: .greedy))
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch is CancellationError {
            throw AgentModelError.interrupted
        }
        let latency = start.duration(to: clock.now)
        let usage = await measure(session: session, schema: Output.generationSchema, instructions: instructions, prompt: prompt, response: response.rawContent.jsonString)
        return (response.content, usage, latency)
    }

    private func measure(session: LanguageModelSession, schema: GenerationSchema, instructions: String, prompt: String, response: String) async -> TokenUsage? {
        #if compiler(>=6.3)
        if #available(iOS 26.4, macOS 26.4, *) {
            do {
                let transcript = Array(session.transcript)
                let responses = transcript.filter { if case .response = $0 { true } else { false } }
                let total = try await model.tokenCount(for: transcript)
                let output = try await model.tokenCount(for: responses)
                // Counted separately and added, so this is an upper bound if
                // the prompt entry already includes the schema.
                let schemaTokens = try await model.tokenCount(for: schema)
                return TokenUsage(inputTokens: total - output + schemaTokens, outputTokens: output)
            } catch {
                return nil
            }
        }
        #endif
        guard estimateWhenUncountable else { return nil }
        let schemaText = (try? String(decoding: JSONEncoder().encode(schema), as: UTF8.self)) ?? String(describing: schema)
        return TokenUsage(
            inputTokens: Self.estimate(instructions) + Self.estimate(prompt) + Self.estimate(schemaText),
            outputTokens: Self.estimate(response)
        )
    }

    /// TN3193: roughly three to four characters per token for English.
    static func estimate(_ text: String) -> Int {
        Int((Double(text.count) / 3.5).rounded(.up))
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> AgentModelError {
        switch error {
        case .exceededContextWindowSize: .contextWindowExceeded
        case .guardrailViolation: .guardrailViolation
        case .rateLimited, .concurrentRequests: .interrupted
        case .assetsUnavailable: .unavailable(reason: "model assets unavailable")
        case .unsupportedLanguageOrLocale: .unsupported
        default: .invalidOutput(String(describing: error))
        }
    }
}
