import StarlingCore
import StarlingFeatures
import SwiftUI

/// Standing rules: say them in plain language, review what Starling
/// understood, then save (brief 2.5).
struct RulesEditorView: View {
    @Bindable var model: RulesEditorModel

    var body: some View {
        Form {
            switch model.phase {
            case .loading:
                ProgressView()
            case .writing, .saved:
                compose
                if let saved = model.saved {
                    SavedRulesSection(rules: saved.rules, formatter: model.formatter)
                    Section {
                        Button("Edit rules") { model.editByHand() }
                    }
                }
            case .interpreting:
                Section {
                    ProgressView("Reading this on your iPhone...")
                }
            case .reviewing:
                if let notice = model.notice { NoticeSection(text: notice) }
                RulesReviewSections(
                    draft: $model.draft,
                    flags: model.flags,
                    problems: model.problems,
                    formatter: model.formatter,
                    fromModel: model.interpretedFrom != nil
                )
                Section {
                    Button("Save rules") { Task { await model.save() } }
                        .disabled(!model.problems.isEmpty)
                    Button("Discard changes", role: .destructive) { model.discard() }
                }
            }
        }
        .navigationTitle("Your rules")
    }

    @ViewBuilder private var compose: some View {
        Section {
            TextField("Rules", text: $model.text, prompt: Text("No plans before 10. Never share where I am. Vegetarian."), axis: .vertical)
                .lineLimit(3...6)
            Button(model.saved == nil ? "Turn into rules" : "Add these rules") { Task { await model.interpret() } }
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.saved == nil {
                Button("Write rules by hand") { model.editByHand() }
            }
        } header: {
            Text("Say it your way")
        } footer: {
            Text("Starling reads this on your iPhone and shows you what it understood before saving anything. Your rules never leave your phone.")
        }
        if let notice = model.notice { NoticeSection(text: notice) }
    }
}

struct SavedRulesSection: View {
    let rules: OwnerRules
    let formatter: ValueFormatter

    var body: some View {
        Section("Saved rules") {
            let issues = rules.constraints.constraints.keys.sorted()
            if issues.isEmpty && rules.disclosure.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(issues, id: \.self) { issue in
                ForEach(Array(rules.constraints[issue].enumerated()), id: \.offset) { _, constraint in
                    LabeledContent(formatter.issueName(issue), value: formatter.constraint(constraint))
                }
            }
            ForEach(rules.disclosure, id: \.issue) { rule in
                LabeledContent(formatter.issueName(rule.issue), value: formatter.disclosureAction(rule.action))
            }
        }
    }
}

struct NoticeSection: View {
    let text: String

    var body: some View {
        Section {
            Label(text, systemImage: "info.circle").foregroundStyle(.orange)
        }
    }
}

#if DEBUG
#Preview("Writing") {
    @Previewable @State var model = PreviewSupport.app().rulesEditor
    NavigationStack { RulesEditorView(model: model) }
        .task { await model.load() }
}

#Preview("Reviewing") {
    @Previewable @State var model = PreviewSupport.app().rulesEditor
    NavigationStack { RulesEditorView(model: model) }
        .task {
            await model.load()
            model.text = "no plans before 10, food under $15"
            await model.interpret()
        }
}
#endif
