import Foundation
import FoundationModels
import StarlingCore

/// The model in the core loop (ADR 0016): routing New's free text to a
/// skill, reading its chips, and writing the proposal sentence. Each call
/// runs in a fresh session with greedy sampling, like the AgentModel jobs.
/// Routing and reading remember their answers for the same words
/// (`SkillReadCache`), so re-reading a draft is free and gives the same
/// chips.
extension FoundationModelsAgent: SkillModel {
    public func route(_ utterance: String, among skills: [SkillDescriptor]) async throws -> ModelResult<SkillID?> {
        let owner = try OwnerUtterance(utterance)
        guard !skills.isEmpty else { return ModelResult(value: nil, usage: nil, latency: .zero) }
        let key = SkillReadCache.routeKey(owner.text, skills: skills)
        if let known = skillReads.route(for: key) { return ModelResult(value: known, usage: nil, latency: .zero) }
        let schema = try RouteSchema(skills: skills)
        let (content, usage, latency) = try await generate(schema.schema, instructions: PromptRenderer.routeInstructions, prompt: PromptRenderer.route(owner, skills: skills))
        let skill = try schema.skill(from: content)
        skillReads.remember(route: skill, for: key)
        return ModelResult(value: skill, usage: usage, latency: latency)
    }

    public func intent(from utterance: String, for skill: SkillDescriptor, now: Date, timeZone: TimeZone) async throws -> ModelResult<ParsedIntent> {
        let owner = try OwnerUtterance(utterance)
        let key = SkillReadCache.intentKey(owner.text, skill: skill)
        if let raw = skillReads.intent(for: key) {
            let parsed = try SkillOutputMapping.parsed(raw, utterance: owner.text, skill: skill, now: now, timeZone: timeZone)
            return ModelResult(value: parsed, usage: nil, latency: .zero)
        }
        let schema = try IntentGenerationSchema(skill: skill)
        let (content, usage, latency) = try await generate(schema.schema, instructions: PromptRenderer.intentInstructions, prompt: PromptRenderer.intent(owner))
        let raw = try schema.raw(from: content)
        skillReads.remember(intent: raw, for: key)
        let parsed = try SkillOutputMapping.parsed(raw, utterance: owner.text, skill: skill, now: now, timeZone: timeZone)
        return ModelResult(value: parsed, usage: usage, latency: latency)
    }

    public func proposalText(_ facts: ProposalFacts) async throws -> ModelResult<String> {
        try await proposalText(facts, now: Date())
    }

    /// `now` decides "tonight", "tomorrow", or a weekday.
    public func proposalText(_ facts: ProposalFacts, now: Date) async throws -> ModelResult<String> {
        let time = facts.time.map { PromptRenderer.spokenTime($0.start, now: now, timeZone: facts.timeZone) }
        let (content, usage, latency) = try await generate(try ProposalSentence.schema(), instructions: PromptRenderer.proposalInstructions, prompt: PromptRenderer.proposal(facts, time: time))
        let sentence = try SkillOutputMapping.sentence(try content.value(String.self, forProperty: "sentence"), facts: facts, time: time)
        return ModelResult(value: sentence, usage: usage, latency: latency)
    }
}
