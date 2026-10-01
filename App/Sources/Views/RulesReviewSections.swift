import StarlingCore
import StarlingFeatures
import SwiftUI

/// The editable review of interpreted rules, shared by the rules editor and
/// the Down screen. Every row can be changed or deleted before saving.
struct RulesReviewSections: View {
    @Binding var draft: RulesDraft
    let flags: [UUID: String]
    let problems: [RulesDraft.Problem]
    let formatter: ValueFormatter
    /// True when rows came from the model, so the review warning shows.
    let fromModel: Bool
    /// One row per disclosable issue, shown whether or not the rules mention
    /// it (ADR 0161: interpretation can miss a "never share").
    let sharingRows: [RulesDraft.SharingRow]
    let setSharing: (DisclosureRule.Action, IssueKey) -> Void

    var body: some View {
        Section {
            if draft.items.isEmpty {
                Text("No rules yet.").foregroundStyle(.secondary)
            }
            ForEach($draft.items) { $item in
                RuleRow(item: $item, flag: flags[item.id], problem: problem(for: item.id), formatter: formatter)
            }
            .onDelete { draft.items.remove(atOffsets: $0) }
            addRuleMenu
        } header: {
            Text("Rules")
        } footer: {
            if fromModel {
                Text("Check every row. The on-device model can add things you didn't say or miss things you did. Swipe to delete.")
            }
        }

        Section {
            ForEach(sharingRows) { row in
                SharingRowView(row: row, flag: row.ruleID.flatMap { flags[$0] }, problem: row.ruleID.flatMap(problem(for:)), formatter: formatter) {
                    setSharing($0, row.issue)
                }
            }
        } header: {
            Text("What may leave your phone")
        } footer: {
            Text("Check every topic. Starling can miss a \"never share\" you wrote, so set it here. Topics you leave on \"Ask me each time\" show a sheet before anything is sent.")
        }

        let general = problems.filter { $0.itemID == nil }
        if !general.isEmpty {
            Section {
                ForEach(general, id: \.self) { Text($0.message).foregroundStyle(.red) }
            }
        }
    }

    private var addRuleMenu: some View {
        Menu("Add a rule") {
            Button("Only at certain times") { draft.add(.within, issue: .time) }
            Button("Daily hours") { draft.add(.dailyWindow, issue: .time) }
            Button("Likes and avoids") { draft.add(.prefers, issue: .activity) }
            Button("Spend at most") { draft.add(.atMost, issue: .budget) }
            Button("Group size") { draft.add(.countBetween, issue: .partySize) }
        }
    }

    private func problem(for id: UUID) -> String? {
        problems.first { $0.itemID == id }?.message
    }
}

private struct RuleRow: View {
    @Binding var item: RulesDraft.Item
    let flag: String?
    let problem: String?
    let formatter: ValueFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(formatter.issueName(item.issue)).font(.headline)
            editor
            Toggle("Flexible", isOn: Binding(get: { item.strength == .soft }, set: { item.strength = $0 ? .soft : .hard }))
                .font(.subheadline)
            Notes(flag: flag, problem: problem)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var editor: some View {
        switch item.kind {
        case .within:
            ForEach($item.slots) { $slot in
                VStack(alignment: .leading) {
                    DatePicker("From", selection: $slot.start)
                    DatePicker("To", selection: $slot.end)
                }
            }
            Button("Add a time") {
                let start = item.slots.last?.end ?? Date()
                item.slots.append(RulesDraft.Slot(start: start, end: start.addingTimeInterval(2 * 3600)))
            }
            .font(.subheadline)
        case .dailyWindow:
            DatePicker("From", selection: minutes($item.fromMinute), displayedComponents: .hourAndMinute)
            Toggle("Until midnight", isOn: Binding(get: { item.toMinute == 1440 }, set: { item.toMinute = $0 ? 1440 : 22 * 60 }))
            if item.toMinute < 1440 {
                DatePicker("To", selection: minutes($item.toMinute), displayedComponents: .hourAndMinute)
            }
        case .prefers:
            KeywordField(title: "Likes", text: $item.likedText)
            KeywordField(title: "Avoids", text: $item.avoidedText)
        case .atMost, .atLeast:
            Picker("Limit", selection: $item.kind) {
                Text("At most").tag(RulesDraft.Kind.atMost)
                Text("At least").tag(RulesDraft.Kind.atLeast)
            }
            .pickerStyle(.segmented)
            TextField("Amount", value: $item.amount, format: .currency(code: item.currency))
                .keyboardType(.decimalPad)
        case .mustBe:
            Toggle("Must be yes", isOn: $item.flag)
        case .countBetween:
            Stepper("At least \(item.minCount)", value: $item.minCount, in: 0...ProtocolLimits.maxCount)
            Stepper("At most \(item.maxCount)", value: $item.maxCount, in: 0...ProtocolLimits.maxCount)
        }
    }

    /// Minutes after midnight as a time of day for a DatePicker.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return Binding(
            get: { midnight.addingTimeInterval(TimeInterval(value.wrappedValue * 60)) },
            set: {
                let parts = calendar.dateComponents([.hour, .minute], from: $0)
                value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// Keeps the raw text while typing so a trailing comma is not eaten, and
/// hands the parsed list to the draft on every change.
private struct KeywordField: View {
    let title: String
    @Binding var text: String
    @State private var raw: String

    init(title: String, text: Binding<String>) {
        self.title = title
        _text = text
        _raw = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextField(title, text: $raw, prompt: Text("\(title): comma separated"))
            .textInputAutocapitalization(.never)
            .onChange(of: raw) { _, new in text = new }
    }
}

/// A topic's sharing: an always-visible "Never share" toggle, and when it is
/// off, whether to ask each time or share with on-device agents.
private struct SharingRowView: View {
    let row: RulesDraft.SharingRow
    let flag: String?
    let problem: String?
    let formatter: ValueFormatter
    let set: (DisclosureRule.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Never share \(formatter.issueName(row.issue).lowercased())", isOn: Binding(
                get: { row.action == .never },
                set: { set($0 ? .never : .askEachTime) }
            ))
            .disabled(row.choices == [.never])
            if row.action != .never {
                Picker("Otherwise", selection: Binding(get: { row.action }, set: { set($0) })) {
                    ForEach(row.choices.filter { $0 != .never }, id: \.self) {
                        Text(formatter.disclosureAction($0)).tag($0)
                    }
                }
                .font(.subheadline)
            }
            if row.fromSavedRules {
                Text("Set by your saved rules. This Down? can only be stricter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Notes(flag: flag, problem: problem)
        }
    }
}

private struct Notes: View {
    let flag: String?
    let problem: String?

    var body: some View {
        if let flag {
            Label(flag, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        }
        if let problem {
            Label(problem, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red)
        }
    }
}
