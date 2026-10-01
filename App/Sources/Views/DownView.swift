import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// Down?: say what you're up for, review it, and hear about a friend only
/// when they're up for the same thing (brief 2.6).
struct DownView: View {
    @Bindable var model: DownModel

    var body: some View {
        Form {
            Section {
                StatusMark(state: MarkState(model.status))
                    .frame(width: 120, height: 120)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            if let notice = model.notice { NoticeSection(text: notice) }

            switch model.phase {
            case .composing:
                compose
            case .interpreting:
                Section { ProgressView("Reading this on your iPhone...") }
            case .reviewing:
                review
            case .starting:
                Section { ProgressView("Starting...") }
            case .active:
                if let active = model.active { status(active) }
            }

            if !model.matches.isEmpty {
                Section("Matches") {
                    ForEach(model.matches) { MatchRowView(row: $0) }
                }
            }
        }
        .navigationTitle("Down?")
        // The owner may have edited saved rules in the Rules tab meanwhile.
        .onAppear { Task { await model.refreshStandingRules() } }
    }

    @ViewBuilder private var compose: some View {
        Section {
            TextField("Intent", text: $model.text, prompt: Text("Free tonight, want food, under $15"), axis: .vertical)
                .lineLimit(2...5)
            Button("Check with friends") { Task { await model.interpret() } }
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Write it by hand") { Task { await model.editByHand() } }
        } header: {
            Text("What are you up for?")
        } footer: {
            Text("You'll see what Starling understood before anything is checked. Friends hear about it only if they're up for the same thing.")
        }
    }

    @ViewBuilder private var review: some View {
        RulesReviewSections(
            draft: $model.draft,
            flags: model.flags,
            problems: model.draft.problems,
            formatter: model.formatter,
            fromModel: model.interpretedFrom != nil,
            sharingRows: model.sharingRows,
            setSharing: model.setSharing
        )
        if !model.sharingWarnings.isEmpty || model.matchingNote != nil {
            Section {
                ForEach(model.sharingWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let note = model.matchingNote {
                    Label(note, systemImage: "eye").font(.footnote)
                }
            }
        }
        Section {
            Picker("How keen", selection: $model.level) {
                Text("Down").tag(DownLevel.down)
                Text("Maybe").tag(DownLevel.maybe)
            }
            .pickerStyle(.segmented)
            Picker("For", selection: $model.duration) {
                ForEach(DownDuration.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("How keen are you?")
        } footer: {
            Text("A friend learns you said maybe only if they're interested too. Your saved rules also apply.")
        }
        Section {
            Button(model.level == .down ? "I'm down" : "I'm a maybe") { Task { await model.goDown() } }
                .disabled(!model.draft.problems.isEmpty)
            Button("Start over", role: .destructive) { model.discard() }
        }
    }

    @ViewBuilder private func status(_ active: DownModel.Active) -> some View {
        Section {
            LabeledContent(active.level == .down ? "You're down" : "You're a maybe", value: "until \(active.expiresAt.formatted(date: .omitted, time: .shortened))")
            if let friends = active.checkingFriends {
                Text(friends == 0 ? "No paired friends are reachable right now." : "Checking with \(friends) \(friends == 1 ? "friend" : "friends").")
                    .foregroundStyle(.secondary)
            } else {
                Text("Starting to check with friends...").foregroundStyle(.secondary)
            }
            Button("Withdraw", role: .destructive) { Task { await model.withdraw() } }
        } footer: {
            Text("Withdrawing tells friends nothing beyond \"no match\".")
        }
    }
}

extension MarkState {
    /// DownEvent to mark, per docs/requests/BR.md. `.negotiating` is never
    /// used: nothing in Down may show that a friend's intent overlaps before
    /// a mutual match, and `DownStatus` has no case that could produce it.
    init(_ status: DownStatus) {
        switch status {
        case .idle: self = .idle
        case .searching: self = .searching
        case .match: self = .match
        case .noMatch: self = .noMatch
        }
    }
}

private struct MatchRowView: View {
    let row: DownModel.MatchRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.bothDown ? "You and \(row.friendName) are both down" : "You and \(row.friendName) are both interested")
                .font(.headline)
            ForEach(row.lines, id: \.self) { line in
                LabeledContent(line.title, value: line.detail ?? "")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Compose") {
    @Previewable @State var model = PreviewSupport.app().down!
    NavigationStack { DownView(model: model) }
}

#Preview("Review") {
    @Previewable @State var model = PreviewSupport.app().down!
    NavigationStack { DownView(model: model) }
        .task {
            model.text = "free tonight, want food, under $15"
            await model.interpret()
        }
}
#endif
