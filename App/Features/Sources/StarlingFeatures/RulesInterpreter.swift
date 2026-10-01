import Foundation
import StarlingCore

/// Runs `AgentModel.interpret` on the owner's words and turns the result, or
/// the failure, into something a screen can show. Shared by the rules editor
/// and the Down screen.
public struct RulesInterpreter: Sendable {
    public enum Outcome: Hashable, Sendable {
        /// A draft for review. Rows are marked as model-produced.
        case draft(RulesDraft)
        /// The model cannot run; the owner can still write rules by hand.
        case handEdit(notice: String)
        case failed(String)
    }

    public static let standingIssues: [IssueKey] = [.time, .budget, .activity, .diet, .place]
    public static let intentIssues: [IssueKey] = [.time, .activity, .budget, .place, .partySize]

    private let agent: (any AgentModel)?
    private let issues: [IssueKey]
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    public init(agent: (any AgentModel)?, issues: [IssueKey], timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.agent = agent
        self.issues = issues
        self.timeZone = timeZone
        self.now = now
    }

    public func interpret(_ text: String) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Write something first.") }
        guard let utterance = try? OwnerUtterance(trimmed) else {
            return .failed("Keep it under \(ProtocolLimits.maxOwnerUtteranceCharacters) characters.")
        }
        guard let agent else {
            return .handEdit(notice: "This build has no on-device model. Add your rules by hand.")
        }
        do {
            let context = InterpretationContext(now: now(), timeZone: timeZone, issues: issues)
            let result = try await agent.interpret(utterance, context: context)
            return .draft(RulesDraft(result.value, origin: .model))
        } catch let error as AgentModelError {
            switch error {
            case .unavailable, .unsupported:
                return .handEdit(notice: "The on-device model isn't available on this iPhone right now. Add your rules by hand.")
            case .contextWindowExceeded:
                return .failed("That's too long for the on-device model. Try fewer words.")
            case .guardrailViolation:
                return .failed("The on-device model wouldn't read that. Try rephrasing.")
            case .invalidOutput:
                return .failed("The model's answer didn't make sense. Try again, or add rules by hand.")
            case .interrupted:
                return .failed("The model was interrupted. Keep Starling open and try again.")
            }
        } catch {
            return .failed("Something went wrong reading that. Try again, or add rules by hand.")
        }
    }
}
