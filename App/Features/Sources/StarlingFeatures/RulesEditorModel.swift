import Foundation
import Observation
import StarlingCore

/// The rules editor: plain language, then interpretation, then a mandatory
/// review of every row before anything is saved (brief 2.5).
@MainActor
@Observable
public final class RulesEditorModel {
    public enum Phase: Hashable, Sendable {
        case loading
        /// Writing rules in plain language.
        case writing
        case interpreting
        /// Reviewing and editing `draft`. The only phase that can save.
        case reviewing
        /// Showing the saved rules.
        case saved
    }

    public var text = ""
    public var draft = RulesDraft.empty
    public private(set) var phase = Phase.loading
    public private(set) var notice: String?
    public private(set) var saved: SavedRules?
    /// True when the saved rules exist but could not be read. Different from
    /// "nothing saved": the app keeps every send denied until the owner
    /// saves rules again (review finding 2 on PR #27).
    public private(set) var loadFailed = false
    /// The words the current draft's model rows came from.
    public private(set) var interpretedFrom: String?

    /// Called after the rules are saved, for example to update the policy.
    public var onSaved: @MainActor () async -> Void = {}

    private let interpreter: RulesInterpreter
    private let store: any RulesStore
    private let now: @Sendable () -> Date
    public let formatter: ValueFormatter

    public init(interpreter: RulesInterpreter, store: any RulesStore, formatter: ValueFormatter = ValueFormatter(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.interpreter = interpreter
        self.store = store
        self.formatter = formatter
        self.now = now
    }

    /// Advisory flags for model-produced rows (`RulesDraft.reviewFlags`).
    public var flags: [UUID: String] {
        interpretedFrom.map { draft.reviewFlags(for: $0, formatter: formatter) } ?? [:]
    }

    public var problems: [RulesDraft.Problem] { draft.problems }

    public func load() async {
        do {
            saved = try await store.load()
            loadFailed = false
        } catch {
            loadFailed = true
            notice = "Your saved rules couldn't be read, so Starling won't send anything until you save your rules again."
        }
        phase = saved == nil ? .writing : .saved
    }

    /// Interprets `text` and opens the review. New rows are added to any
    /// saved rules rather than replacing them.
    public func interpret() async {
        guard phase == .writing || phase == .saved else { return }
        let previous = phase
        phase = .interpreting
        notice = nil
        switch await interpreter.interpret(text) {
        case .draft(let interpreted):
            var draft = RulesDraft(saved?.rules ?? .empty)
            draft.items += interpreted.items
            draft.mergeSharing(interpreted.sharing)
            self.draft = draft
            interpretedFrom = text
            phase = .reviewing
        case .handEdit(let notice):
            self.notice = notice
            editByHand()
        case .failed(let message):
            notice = message
            phase = previous
        }
    }

    /// Opens the review on the saved rules (or nothing) without the model.
    public func editByHand() {
        draft = RulesDraft(saved?.rules ?? .empty)
        interpretedFrom = nil
        phase = .reviewing
    }

    /// Saves the reviewed draft. Returns false and leaves the review open
    /// when a row has a problem.
    @discardableResult
    public func save() async -> Bool {
        guard phase == .reviewing else { return false }
        do {
            let rules = SavedRules(rules: try draft.build(), savedAt: now())
            try await store.save(rules)
            saved = rules
            loadFailed = false
            text = ""
            interpretedFrom = nil
            notice = nil
            phase = .saved
            await onSaved()
            return true
        } catch is RulesDraftError {
            notice = "Fix the rows marked in red before saving."
            return false
        } catch {
            notice = "Your rules couldn't be saved. Try again."
            return false
        }
    }

    /// Leaves the review without saving.
    public func discard() {
        guard phase == .reviewing else { return }
        draft = .empty
        interpretedFrom = nil
        notice = nil
        phase = saved == nil ? .writing : .saved
    }
}
